# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.Block do
  alias Chain.{Block, BlockCache, State, Transaction, Header}

  @enforce_keys [:coinbase]
  defstruct transactions: [], header: %Chain.Header{}, receipts: [], coinbase: nil

  @type t :: %Chain.Block{
          transactions: [Chain.Transaction.t()],
          header: Chain.Header.t(),
          receipts: [Chain.TransactionReceipt.t()],
          coinbase: any()
        }

  # @min_difficulty 131072
  @min_difficulty 65536
  @max_difficulty 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  def header(%Block{header: header}), do: header
  def txhash(%Block{header: header}), do: header.transaction_hash

  def parent(%Block{} = block), do: Chain.block_by_hash(parent_hash(block))
  def parent_hash(%Block{header: header}), do: header.previous_block
  def nonce(%Block{header: header}), do: header.nonce
  def miner(%Block{header: header}), do: Header.recover_miner(header)
  def state_hash(%Block{header: header}), do: Chain.Header.state_hash(header)
  @spec hash(Chain.Block.t()) :: binary()
  # Fix for creating a signature of a non-exisiting block in registry_test.ex
  def hash(nil), do: nil
  def hash(%Block{header: header}), do: header.block_hash
  @spec transactions(Chain.Block.t()) :: [Chain.Transaction.t()]
  def transactions(%Block{transactions: transactions}), do: transactions
  @spec timestamp(Chain.Block.t()) :: non_neg_integer()
  def timestamp(%Block{header: header}), do: header.timestamp
  def receipts(%Block{receipts: receipts}), do: receipts

  def has_state?(%Block{header: %{state_hash: %Chain.State{}}}) do
    true
  end

  def has_state?(_block) do
    false
  end

  @spec state(Chain.Block.t()) :: Chain.State.t()
  def state(%Block{} = block) do
    if has_state?(block) do
      # This is actually a full %Chain.State{} object when has_state?() == true
      block.header.state_hash
    else
      Model.ChainSql.state(hash(block))
    end
  end

  @spec valid?(Chain.Block.t()) :: boolean()
  def valid?(block) do
    case validate(block) do
      %Chain.Block{} -> true
      _ -> false
    end
  end

  defp test(test, fun) do
    {test, fun.()}
  end

  defp tc(test, fun) do
    Model.Stats.tc(test, fun)
  end

  @spec validate(Chain.Block.t()) :: Chain.Block.t() | {non_neg_integer(), any()}
  def validate(block) do
    # IO.puts("Block #{number(block)}.: #{length(transactions(block))}txs")

    with {_, %Block{}} <- {:is_block, block},
         {_, pa = %Block{}} <-
           test(:has_parent, fn -> parent(block) end),
         {_, true} <-
           test(:correct_number, fn -> Block.number(block) == Block.number(pa) + 1 end),
         {_, true} <- test(:hash_valid, fn -> hash_valid?(block) end),
         {_, []} <-
           test(:tx_valid, fn ->
             Enum.map(transactions(block), &Transaction.validate/1)
             |> Enum.reject(fn tx -> tx == true end)
           end),
         {_, true} <-
           test(:tx_hash_valid, fn ->
             Diode.hash(encode_transactions(transactions(block))) == txhash(block)
           end),
         {_, sim_block} <- test(:simulate, fn -> simulate(block) end),
         {_, true} <- test(:state_equal, fn -> state_equal(sim_block, block) end) do
      %{sim_block | header: %{block.header | state_hash: sim_block.header.state_hash}}
    else
      {nr, error} -> {nr, error}
    end
  end

  defp state_equal(sim_block, block) do
    if state_hash(sim_block) != state_hash(block) do
      # can inject code here to produce debug output
      # state_a = Block.state(sim_block)
      # state_b = Block.state(block)
      # diff = Chain.State.difference(state_a, state_b)
      # :io.format("State non equal:~p~n", [diff])
      false
    else
      true
    end
  end

  def hash_valid?(block) do
    with %Block{} <- block,
         header <- header(block),
         hash <- hash(block),
         ^hash <- Header.update_hash(header).block_hash,
         true <- hash_in_target?(block, hash) do
      true
    else
      _ -> false
    end
  end

  @spec hash_in_target?(Chain.Block.t(), binary) :: boolean
  def hash_in_target?(block, hash) do
    Hash.integer(hash) < hash_target(block)
  end

  @spec hash_target(Chain.Block.t()) :: integer
  def hash_target(block) do
    blockRef = parent(block)

    # Calculating stake weight as
    # ( stake / 1000 )²  but no less than 1
    #
    # For two decimal accuracy we calculcate in two steps:
    # (( stake / 100 )² * max_diff) / (10² * difficulty_block)
    #
    stake =
      if blockRef == nil do
        1
      else
        Contract.Registry.minerValue(0, Block.coinbase(block), blockRef)
        |> div(Shell.ether(1000))
        |> max(1)
        |> min(50)
      end

    div(stake * stake * @max_difficulty, difficulty(block))
  end

  @doc "Creates a new block and stores the generated state in cache file"
  @spec create(
          Chain.Block.t(),
          [Chain.Transaction.t()],
          Wallet.t(),
          non_neg_integer(),
          true | false
        ) ::
          Chain.Block.t()
  def create(%Block{} = parent, transactions, miner, time, trace? \\ false) do
    block =
      tc(:create_block, fn ->
        %Block{
          header: %Header{
            previous_block: hash(parent),
            number: number(parent) + 1,
            timestamp: time
          },
          coinbase: miner
        }
      end)

    {diff, ret} =
      :timer.tc(fn ->
        Enum.reduce(transactions, {state(parent), [], []}, fn %Transaction{} = tx,
                                                              {%State{} = state, txs, rcpts} ->
          case Transaction.apply(tx, block, state, trace: trace?) do
            {:ok, state, rcpt} ->
              {state, txs ++ [tx], rcpts ++ [rcpt]}

            {:error, message} ->
              :io.format("Error in transaction: ~p (~p)~n", [message, Transaction.hash(tx)])
              {state, txs, rcpts}
          end
        end)
      end)

    Model.Stats.incr(:create_tx, diff)
    {nstate, transactions, receipts} = ret

    if diff > 50_000 and block.header.previous_block != nil do
      IO.puts(
        "Slow block #{length(transactions)}txs: #{diff / 1000}ms parent:(#{
          Base16.encode(block.header.previous_block)
        })"
      )
    end

    header =
      tc(:create_header, fn ->
        %Header{
          block.header
          | state_hash: tc(:optimize, fn -> Chain.State.optimize(nstate) end),
            transaction_hash: Diode.hash(encode_transactions(transactions))
        }
      end)

    tc(:create_body, fn ->
      %Block{block | transactions: transactions, header: header, receipts: receipts}
    end)
  end

  @spec encode_transactions(any()) :: binary()
  def encode_transactions(transactions) do
    BertExt.encode!(Enum.map(transactions, &Transaction.to_rlp/1))
  end

  @spec simulate(Chain.Block.t()) :: Chain.Block.t()
  def simulate(%Block{} = block) do
    tc(:simulate, fn ->
      parent =
        if Block.number(block) >= 1 do
          %Chain.Block{} = parent(block)
        else
          Chain.GenesisFactory.testnet_parent()
        end

      create(parent, transactions(block), miner(block), timestamp(block), false)
    end)
  end

  @spec sign(Block.t(), Wallet.t()) :: Block.t()
  def sign(%Block{} = block, miner) do
    header =
      header(block)
      |> Header.sign(miner)
      |> Header.update_hash()

    %Block{block | header: header}
  end

  @spec transactionIndex(Chain.Block.t(), Chain.Transaction.t()) ::
          nil | non_neg_integer()
  def transactionIndex(%Block{} = block, %Transaction{} = tx) do
    Enum.find_index(transactions(block), fn elem ->
      elem == tx
    end)
  end

  @spec difficulty(Block.t()) :: non_neg_integer()
  def difficulty(%Block{} = block) do
    if Diode.dev_mode?() do
      1
    else
      do_difficulty(block)
    end
  end

  defp do_difficulty(%Block{} = block) do
    parent = parent(block)

    if parent == nil do
      @min_difficulty
    else
      delta = timestamp(block) - timestamp(parent)
      diff = BlockCache.difficulty(parent)
      step = div(diff, 10)

      diff =
        if delta < Chain.blocktimeGoal() do
          diff + step
        else
          diff - step
        end

      if diff < @min_difficulty do
        @min_difficulty
      else
        diff
      end
    end
  end

  @spec totalDifficulty(Block.t()) :: non_neg_integer()
  def totalDifficulty(%Block{} = block) do
    parent = Block.parent(block)

    # Explicit usage of Block and BlockCache cause otherwise cache filling
    # becomes self-recursive problem
    if parent == nil do
      Block.difficulty(block)
    else
      BlockCache.totalDifficulty(parent) + Block.difficulty(block)
    end
  end

  @spec number(Block.t()) :: non_neg_integer()
  def number(%Block{header: %Chain.Header{number: number}}) do
    number
  end

  @spec gas_price(Chain.Block.t()) :: non_neg_integer()
  def gas_price(%Block{} = block) do
    price =
      Enum.reduce(transactions(block), nil, fn tx, price ->
        if price == nil or price > Transaction.gas_price(tx) do
          Transaction.gas_price(tx)
        else
          price
        end
      end)

    case price do
      nil -> 0
      _ -> price
    end
  end

  def epoch(%Block{} = block) do
    div(number(block), Chain.epoch_length())
    # Contract.Registry.epoch(block)
  end

  @spec gasUsed(Block.t()) :: non_neg_integer()
  def gasUsed(%Block{} = block) do
    Enum.reduce(receipts(block), 0, fn receipt, acc -> acc + receipt.gas_used end)
  end

  @spec transactionReceipt(Chain.Block.t(), Chain.Transaction.t()) ::
          Chain.TransactionReceipt.t()
  def transactionReceipt(%Block{} = block, %Transaction{} = tx) do
    Enum.at(receipts(block), transactionIndex(block, tx))
  end

  @spec transactionGas(Chain.Block.t(), Chain.Transaction.t()) :: non_neg_integer()
  def transactionGas(%Block{} = block, %Transaction{} = tx) do
    transactionReceipt(block, tx).gas_used
  end

  @spec transactionStatus(Chain.Block.t(), Chain.Transaction.t()) :: 0 | 1
  def transactionStatus(%Block{} = block, %Transaction{} = tx) do
    case transactionReceipt(block, tx).msg do
      :evmc_revert -> 0
      :ok -> 1
      _other -> 0
    end
  end

  @spec transactionOut(Chain.Block.t(), Chain.Transaction.t()) :: binary() | nil
  def transactionOut(%Block{} = block, %Transaction{} = tx) do
    transactionReceipt(block, tx).evmout
  end

  def logs(%Block{} = block) do
    List.zip([transactions(block), receipts(block)])
    |> Enum.map(fn {tx, rcpt} ->
      Enum.map(rcpt.logs, fn log ->
        {address, topics, data} = log

        # Note: truffle is picky on the size of the address, failed before 'Hash.to_address()' call.
        %{
          "transactionIndex" => Block.transactionIndex(block, tx),
          "transactionHash" => Transaction.hash(tx),
          "blockHash" => Block.hash(block),
          "blockNumber" => Block.number(block),
          "address" => Hash.to_address(address),
          "data" => data,
          "topics" => topics,
          "type" => "mined"
        }
      end)
    end)
    |> List.flatten()
    |> Enum.with_index(0)
    |> Enum.map(fn {log, idx} ->
      Map.put(log, "logIndex", idx)
    end)
  end

  @spec increment_nonce(Chain.Block.t()) :: Chain.Block.t()
  def increment_nonce(%Block{header: header} = block) do
    %{block | header: %{header | nonce: nonce(block) + 1}}
  end

  @doc """
    export removes additional internal field in the block record
    and prepares it for export through public apis or to the disk
  """
  @spec export(Chain.Block.t()) :: Chain.Block.t()
  def export(block) do
    %{strip_state(block) | coinbase: nil, receipts: []}
  end

  @spec export(Chain.Block.t()) :: Chain.Block.t()
  def strip_state(block) do
    %{block | header: Chain.Header.strip_state(block.header)}
  end

  def printable(nil) do
    "nil"
  end

  def printable(block) do
    author = Wallet.words(Block.miner(block))

    prefix =
      Block.hash(block)
      |> binary_part(0, 5)
      |> Base16.encode(false)

    "##{Block.number(block)}[#{prefix}] @#{author}"
  end

  #########################################################
  ###### FUNCTIONS BELOW THIS LINE ARE STILL JUNK #########
  #########################################################

  @spec size(Block.t()) :: non_neg_integer()
  def size(%Block{} = block) do
    # TODO, needs fixed external format
    byte_size(BertInt.encode!(block))
  end

  @spec logsBloom(Block.t()) :: <<_::528>>
  def logsBloom(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  def coinbase(block = %Block{coinbase: nil}) do
    miner(block) |> Wallet.address!() |> :binary.decode_unsigned()
  end

  def coinbase(%Block{coinbase: coinbase}) do
    coinbase |> Wallet.address!() |> :binary.decode_unsigned()
  end

  @spec gasLimit(Block.t()) :: non_neg_integer()
  def gasLimit(%Block{} = _block) do
    Chain.gasLimit()
  end

  @spec extraData(Block.t()) :: <<_::528>>
  def extraData(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  @spec receiptsRoot(Block.t()) :: <<_::528>>
  def receiptsRoot(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end
end
