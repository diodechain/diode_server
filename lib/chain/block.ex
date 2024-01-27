# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Block do
  alias Chain.{Block, BlockCache, State, Transaction, Header}
  alias Model.ChainSql
  require Logger

  @enforce_keys [:coinbase]
  defstruct transactions: [], header: %Chain.Header{}, receipts: [], coinbase: nil

  @type t :: %Chain.Block{
          transactions: [Chain.Transaction.t()],
          header: Chain.Header.t(),
          receipts: [Chain.TransactionReceipt.t()],
          coinbase: any()
        }

  @type ref :: <<_::256>> | %Chain.Block{}

  @min_difficulty 65536
  @max_difficulty 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  def header(%Block{header: header}), do: header
  def txhash(%Block{header: header}), do: header.transaction_hash

  def parent_hash(%Block{header: header}), do: header.previous_block
  def nonce(%Block{header: header}), do: header.nonce
  def state_hash(%Block{header: header}), do: Header.state_hash(header)
  @spec hash(Chain.Block.t()) :: binary() | nil
  # Fix for creating a signature of a non-exisiting block in registry_test.ex
  def hash(nil), do: nil
  def hash(%Block{header: header}), do: header.block_hash
  @spec transactions(Chain.Block.t()) :: [Chain.Transaction.t()]
  def transactions(%Block{transactions: transactions}), do: transactions
  @spec timestamp(Chain.Block.t()) :: non_neg_integer()
  def timestamp(%Block{header: header}), do: header.timestamp
  def receipts(%Block{receipts: receipts}), do: receipts

  @spec state(Chain.Block.t()) :: Chain.State.t()
  def state(%Block{header: %{state_hash: state = %Chain.State{}}}) do
    state
  end

  def state(%Block{} = block) do
    BlockProcess.maybe_cache(hash(block), :state, fn -> Model.ChainSql.state(hash(block)) end)
  end

  def state_tree(%Block{} = block) do
    BlockProcess.maybe_cache(hash(block), :state_tree, fn ->
      state(block)
      |> Chain.State.tree()
      |> MerkleTree.merkle()
    end)
  end

  def account_tree(%Block{} = block, account_id) do
    BlockProcess.maybe_cache(hash(block), {:account_tree, account_id}, fn ->
      state(block)
      |> Chain.State.account(account_id)
      |> case do
        nil ->
          nil

        acc ->
          acc
          |> Chain.Account.tree()
          |> MerkleTree.merkle()
      end
    end)
  end

  @doc "For snapshot exporting ensure the block has a full state object"
  @spec ensure_state(Chain.Block.t()) :: Chain.Block.t()
  def ensure_state(block = %Block{header: %{state_hash: %Chain.State{}}}) do
    block
  end

  def ensure_state(%Block{} = block) do
    ensure_state(block, state(block))
  end

  @spec ensure_state(Chain.Block.t(), Chain.State.t()) :: Chain.Block.t()
  def ensure_state(%Block{} = block, %Chain.State{} = state) do
    %Block{block | header: %{block.header | state_hash: state}}
  end

  defp test(test, fun) do
    {test, fun.()}
  end

  defp test_tc(test, fun) do
    {test, tc(test, fun)}
  end

  defp tc(test, fun) do
    Stats.tc(test, fun)
  end

  @blockquick_margin div(Chain.window_size(), 10)
  def in_final_window?(block) do
    nr = number(block)

    if ChainDefinition.check_window(nr) do
      BlockProcess.with_block(last_final(block), &Block.number/1) + Chain.window_size() -
        @blockquick_margin >=
        Block.number(block)
    else
      true
    end
  end

  @spec validate(Chain.Block.t(), boolean()) :: Chain.Block.ref() | {non_neg_integer(), any()}
  # def validate(block, fast \\ false)
  def validate(%Block{} = block, false) do
    # IO.puts("Block #{number(block)}.: #{length(transactions(block))}txs")
    tc(:cache, fn -> BlockCache.cache(block) end)

    with {_, %Block{}} <- {:is_block, block},
         {_, true} <-
           test(:has_parent, fn -> parent_hash(block) == with_parent(block, &hash/1) end),
         {_, true} <-
           test(:correct_number, fn -> number(block) == with_parent(block, &number/1) + 1 end),
         {_, true} <-
           test_tc(:diverse, fn ->
             is_diverse?(ChainDefinition.min_diversity(number(block)), block)
           end),
         {_, true} <-
           test_tc(:in_final_window, fn -> in_final_window?(block) end),
         {_, true} <- test(:hash_valid, fn -> hash_valid?(block) end),
         {_, []} <-
           test_tc(:tx_valid, fn ->
             Enum.map(transactions(block), &Transaction.validate/1)
             |> Enum.reject(fn tx -> tx == true end)
           end),
         {_, true} <- test_tc(:min_tx_fee, fn -> conforms_min_tx_fee?(block) end),
         {_, true} <-
           test(:tx_hash_valid, fn ->
             Diode.hash(encode_transactions(transactions(block))) == txhash(block)
           end),
         {_, sim_block} <- test_tc(:simulate, fn -> simulate(block) end),
         {_, true} <- test_tc(:registry_tx, fn -> has_registry_tx?(sim_block) end),
         {_, true} <- test_tc(:state_equal, fn -> state_equal(sim_block, block) end) do
      # {:reply, self(),
      #  %{sim_block | header: %{block.header | state_hash: sim_block.header.state_hash}}}
      block = %{sim_block | header: %{block.header | state_hash: sim_block.header.state_hash}}
      tc(:put_new_block, fn -> ChainSql.put_new_block(block) end)
      tc(:ets_add_alt, fn -> Chain.ets_add_alt(block) end)
      tc(:start_block, fn -> BlockProcess.start_block(block) end)
    else
      {nr, error} -> {nr, error}
    end
  end

  def validate(%Block{} = block, true) do
    # IO.puts("Block #{number(block)}.: #{length(transactions(block))}txs")
    tc(:cache, fn -> BlockCache.cache(block) end)

    with {_, %Block{}} <- {:is_block, block},
         {_, true} <-
           test(:has_parent, fn -> parent_hash(block) == with_parent(block, &hash/1) end),
         {_, true} <-
           test(:correct_number, fn -> number(block) == with_parent(block, &number/1) + 1 end),
         {_, true} <- test(:hash_valid, fn -> hash_valid?(block) end),
         {_, []} <-
           test_tc(:tx_valid, fn ->
             Enum.map(transactions(block), &Transaction.validate/1)
             |> Enum.reject(fn tx -> tx == true end)
           end),
         {_, true} <-
           test(:tx_hash_valid, fn ->
             Diode.hash(encode_transactions(transactions(block))) == txhash(block)
           end),
         {_, sim_block} <- test_tc(:simulate, fn -> simulate(block, true) end),
         {_, true} <- test_tc(:registry_tx, fn -> has_registry_tx?(sim_block) end) do
      block = %{
        sim_block
        | header: %{
            block.header
            | state_hash: %Chain.State{
                sim_block.header.state_hash
                | hash: block.header.state_hash
              }
          }
      }

      tc(:put_new_block, fn -> ChainSql.put_new_block(block) end)
      tc(:ets_add_alt, fn -> Chain.ets_add_alt(block) end)
      tc(:start_block, fn -> BlockProcess.start_block(block) end)
    else
      {nr, error} -> {nr, error}
    end
  end

  def with_parent(block = %Block{}, fun) do
    # These can be recursive and very long time, so we use a timeout
    BlockProcess.with_block(parent_hash(block), fun, :infinity)
  end

  defp conforms_min_tx_fee?(block) do
    if ChainDefinition.min_transaction_fee(number(block)) do
      fee = Contract.Registry.min_transaction_fee(parent_hash(block))
      # We're ignoring the last TX because that is by convention the Registry TX with
      # a gas price of 0
      txs = transactions(block)
      {_, txs} = List.pop_at(txs, length(txs) - 1)
      # :io.format("Min fee: ~p~n", [fee])
      Enum.all?(txs, fn tx ->
        # :io.format("TX fee: ~p~n", [Transaction.gas_price(tx)])
        Transaction.gas_price(tx) >= fee
      end)
    else
      true
    end
  end

  defp has_registry_tx?(block) do
    position = ChainDefinition.block_reward_position(number(block))
    has_registry_tx?(position, block)
  end

  defp has_registry_tx?(:first, block) do
    wallet = miner(block)
    tx = hd(transactions(block))

    Wallet.equal?(Transaction.origin(tx), wallet) and
      Transaction.gas_price(tx) == 0 and
      Transaction.gas_limit(tx) == 1_000_000_000 and
      Transaction.to(tx) == Diode.registry_address() and
      Transaction.data(tx) == ABI.encode_call("blockReward")
  end

  defp has_registry_tx?(:last, block) do
    wallet = miner(block)
    tx = List.last(transactions(block))
    rcpt = List.last(receipts(block))
    # This is are the input parameters for the last transaction
    # and should not include self
    used = gas_used(block) - rcpt.gas_used
    # - rcpt.gas_used * tx.gas_price (always 0)
    fees = gas_fees(block)

    Wallet.equal?(Transaction.origin(tx), wallet) and
      Transaction.gas_price(tx) == 0 and
      Transaction.gas_limit(tx) == 1_000_000_000 and
      Transaction.to(tx) == Diode.registry_address() and
      Transaction.data(tx) == ABI.encode_call("blockReward", ["uint256", "uint256"], [used, fees])
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
    # Calculating stake weight as
    # ( stake / 1000 )²  but no less than 1
    #
    # For two decimal accuracy we calculcate in two steps:
    # (( stake / 100 )² * max_diff) / (10² * difficulty_block)
    #
    stake =
      with_parent(block, fn parent ->
        if parent == nil do
          1
        else
          Contract.Registry.miner_value(0, BlockCache.miner(block), parent)
          |> div(Shell.ether(1000))
          |> max(1)
          |> min(50)
        end
      end)

    diff = BlockCache.difficulty(block)
    div(stake * stake * @max_difficulty, diff)
    # :io.format("hash_target(~p) = ~p (~p * ~p)~n", [Block.printable(block), ret, diff, stake])
    # ret
  end

  @doc "Creates a new block and stores the generated state in cache file"
  @spec create(
          Chain.Block.ref(),
          [Chain.Transaction.t()],
          Wallet.t(),
          non_neg_integer(),
          true | false
        ) ::
          Chain.Block.t()
  def create(parent_ref, transactions, miner, time, trace? \\ false, fast_validation? \\ false) do
    block =
      BlockProcess.with_block(parent_ref, fn parent -> create_empty(parent, miner, time) end)

    Stats.tc(:tx, fn ->
      Enum.reduce(transactions, block, fn %Transaction{} = tx, block ->
        case append_transaction(block, tx, trace?) do
          {:error, _err} -> block
          {:ok, block} -> block
        end
      end)
    end)
    |> finalize_header(fast_validation?)
  end

  @doc "Creates a new block and stores the generated state in cache file"
  @spec create_empty(
          Chain.Block.t(),
          Wallet.t(),
          non_neg_integer()
        ) ::
          Chain.Block.t()
  def create_empty(%Block{} = parent, miner, time) do
    tc(:create_empty, fn ->
      %Block{
        header: %Header{
          previous_block: hash(parent),
          number: number(parent) + 1,
          timestamp: time,
          state_hash: state(parent)
        },
        coinbase: miner
      }
    end)
  end

  def append_transaction(%Block{transactions: txs, receipts: rcpts} = block, tx, trace? \\ false) do
    state = state(block)

    case Transaction.apply(tx, block, state, trace: trace?) do
      {:ok, state, rcpt} ->
        {:ok,
         %Block{
           block
           | transactions: txs ++ [tx],
             receipts: rcpts ++ [rcpt],
             header: %Header{
               block.header
               | state_hash: state
             }
         }}

      {:error, message} ->
        Transaction.print(tx)
        IO.puts("\tError:       #{inspect(message)}")
        {:error, message}
    end
  end

  def finalize_header(%Block{} = block, fast_validation? \\ false) do
    block = ChainDefinition.hardforks(block)

    if fast_validation? do
      block
    else
      tc(:create_header, fn ->
        %Block{
          block
          | header: %Header{
              block.header
              | state_hash: tc(:normalize, fn -> State.normalize(state(block)) end),
                transaction_hash: Diode.hash(encode_transactions(transactions(block)))
            }
        }
      end)
    end
  end

  @spec encode_transactions(any()) :: binary()
  def encode_transactions(transactions) do
    BertExt.encode!(Enum.map(transactions, &Transaction.to_rlp/1))
  end

  @spec simulate(Chain.Block.t()) :: Chain.Block.t()
  def simulate(%Block{} = block, fast_validation? \\ false) do
    parent_ref =
      if Block.number(block) >= 1 do
        Block.parent_hash(block)
      else
        Chain.GenesisFactory.testnet_parent()
      end

    create(
      parent_ref,
      transactions(block),
      miner(block),
      timestamp(block),
      false,
      fast_validation?
    )
  end

  @spec sign(Block.t(), Wallet.t()) :: Block.t()
  def sign(%Block{} = block, miner) do
    header =
      header(block)
      |> Header.sign(miner)
      |> Header.update_hash()

    %Block{block | header: header}
  end

  @spec transaction_index(Chain.Block.t(), Chain.Transaction.t()) ::
          nil | non_neg_integer()
  def transaction_index(%Block{} = block, %Transaction{} = tx) do
    Enum.find_index(transactions(block), fn elem ->
      elem == tx
    end)
  end

  def transaction(%Block{} = block, tx_hash) do
    Enum.find(transactions(block), fn tx -> Transaction.hash(tx) == tx_hash end)
  end

  # The second parameter is an optimizaton for cache bootstrap
  @spec difficulty(Block.t()) :: non_neg_integer()
  def difficulty(%Block{} = block) do
    if Diode.dev_mode?() do
      1
    else
      do_difficulty(block)
    end
  end

  defp do_difficulty(%Block{} = block) do
    with_parent(block, fn
      nil -> nil
      parent -> {timestamp(parent), BlockCache.difficulty(parent)}
    end)
    |> case do
      nil ->
        @min_difficulty

      {parent_timestamp, parent_difficulty} ->
        delta = timestamp(block) - parent_timestamp
        diff = parent_difficulty
        step = div(diff, 10)

        diff =
          if delta < Chain.blocktime_goal() do
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

  # The second parameter is an optimizaton for cache bootstrap
  @spec total_difficulty(Block.t()) :: non_neg_integer()
  def total_difficulty(%Block{} = block) do
    # Explicit usage of Block and BlockCache cause otherwise cache filling
    # becomes self-recursive problem
    if number(block) > 0 do
      Block.difficulty(block) + BlockCache.total_difficulty(parent_hash(block))
    else
      Block.difficulty(block)
    end
  end

  @spec number(Block.t()) :: non_neg_integer()
  def number(%Block{header: %Header{number: number}}) do
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

  @spec gas_used(Block.t()) :: non_neg_integer()
  def gas_used(%Block{} = block) do
    Enum.reduce(receipts(block), 0, fn receipt, acc -> acc + receipt.gas_used end)
  end

  @spec gas_fees(Block.t()) :: non_neg_integer()
  def gas_fees(%Block{} = block) do
    Enum.zip(transactions(block), receipts(block))
    |> Enum.map(fn {tx, rcpt} -> Transaction.gas_price(tx) * rcpt.gas_used end)
    |> Enum.sum()
  end

  @spec transaction_receipt(Chain.Block.t(), Chain.Transaction.t()) ::
          Chain.TransactionReceipt.t()
  def transaction_receipt(%Block{} = block, %Transaction{} = tx) do
    Enum.at(receipts(block), transaction_index(block, tx))
  end

  @spec transaction_gas(Chain.Block.t(), Chain.Transaction.t()) :: non_neg_integer()
  def transaction_gas(%Block{} = block, %Transaction{} = tx) do
    transaction_receipt(block, tx).gas_used
  end

  @spec transaction_status(Chain.Block.t(), Chain.Transaction.t()) :: 0 | 1
  def transaction_status(%Block{} = block, %Transaction{} = tx) do
    case transaction_receipt(block, tx).msg do
      :evmc_revert -> 0
      :ok -> 1
      _other -> 0
    end
  end

  @spec transaction_out(Chain.Block.t(), Chain.Transaction.t()) :: binary() | nil
  def transaction_out(%Block{} = block, %Transaction{} = tx) do
    transaction_receipt(block, tx).evmout
  end

  def logs(%Block{} = block) do
    List.zip([transactions(block), receipts(block)])
    |> Enum.map(fn {tx, rcpt} ->
      Enum.map(rcpt.logs, fn log ->
        {address, topics, data} = log

        # Note: truffle is picky on the size of the address, failed before 'Hash.to_address()' call.
        %{
          "transactionIndex" => Block.transaction_index(block, tx),
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

  @spec set_nonce(Chain.Block.t(), integer()) :: Chain.Block.t()
  def set_nonce(%Block{header: header} = block, nonce) do
    %{block | header: %{header | nonce: nonce}}
  end

  @spec increment_nonce(Chain.Block.t(), integer()) :: Chain.Block.t()
  def increment_nonce(%Block{} = block, n \\ 1) do
    set_nonce(block, nonce(block) + n)
  end

  @spec set_timestamp(Chain.Block.t(), integer()) :: Chain.Block.t()
  def set_timestamp(%Block{header: header} = block, timestamp) do
    %{block | header: %{header | timestamp: timestamp}}
  end

  @doc """
    export removes additional internal field in the block record
    and prepares it for export through public apis or to the disk
  """
  @spec export(Chain.Block.t()) :: Chain.Block.t()
  def export(block) do
    %{strip_state(block) | coinbase: nil, receipts: []}
  end

  @spec strip_state(Chain.Block.t()) :: Chain.Block.t()
  def strip_state(block) do
    %{block | header: Header.strip_state(block.header)}
  end

  def printable(nil) do
    "nil"
  end

  def printable(block) do
    author = Wallet.words(Block.miner(block))

    prefix =
      case Block.hash(block) do
        nil -> "nil"
        other -> binary_part(other, 0, 5) |> Base16.encode(false)
      end

    len = length(transactions(block))
    "##{Block.number(block)}[#{prefix}](#{len} TX) @#{author}"
  end

  def blockquick_window(%Block{header: %Header{number: num}}) when num <= 100 do
    [
      598_746_696_357_369_325_966_849_036_647_255_306_831_025_787_168,
      841_993_309_363_539_165_963_431_397_261_483_173_734_566_208_300,
      1_180_560_991_557_918_668_394_274_720_728_086_333_958_947_256_920
    ]
    |> List.duplicate(34)
    |> List.flatten()
    |> Enum.take(100)
  end

  def blockquick_window(%Block{} = block) do
    parent_hash = parent_hash(block)

    # [_ | window] = get_cached(parent_hash, :blockquick_window, fn -> blockquick_window(parent_hash) end)
    [_ | window] = blockquick_window(parent_hash)
    window ++ [coinbase(block)]
  end

  def blockquick_window(block_hash) when is_binary(block_hash) do
    ChainSql.blockquick_window(block_hash)
  end

  def query_blockquick_window(block_hash) when is_binary(block_hash) do
    #    May 6th -- takes 120ms
    {_, window} =
      Enum.reduce(0..99, {block_hash, []}, fn _, {parent_hash, window} ->
        BlockProcess.with_block(parent_hash, fn block ->
          {parent_hash(block), [coinbase(block) | window]}
        end)
      end)

    window
  end

  def blockquick_scores(%Block{} = block) do
    blockquick_window(block)
    |> Enum.reduce(%{}, fn coinbase, scores ->
      Map.update(scores, coinbase, 1, fn i -> i + 1 end)
    end)
  end

  @spec is_diverse?(non_neg_integer(), Chain.Block.t()) :: boolean
  def is_diverse?(0, _block) do
    true
  end

  def is_diverse?(1, %Block{} = block) do
    miners =
      blockquick_window(block)
      |> Enum.reverse()
      |> Enum.take(4)

    case miners do
      [a, a, a, a] -> false
      _other -> true
    end
  end

  def last_final_hash(%Block{} = block) do
    case last_final(block) do
      block = %Block{} -> Block.hash(block)
      hash when is_binary(hash) -> hash
    end
  end

  # Hash of block 108
  # @anchor_hash <<0, 0, 98, 184, 252, 38, 6, 88, 88, 30, 209, 143, 24, 89, 71, 244, 92, 85, 98, 72,
  #                89, 223, 184, 74, 232, 251, 127, 33, 26, 134, 11, 117>>
  @spec last_final(Chain.Block.t()) :: Chain.Block.ref()
  def last_final(%Block{header: %Header{number: number}} = block) when number < 1 do
    Block.hash(block)
  end

  def last_final(%Block{} = block) do
    prev_final_hash = with_parent(block, &BlockCache.last_final/1)
    window = BlockProcess.with_block(prev_final_hash, &blockquick_scores/1)
    threshold = div(Chain.window_size(), 2)
    gap = Block.number(block) - BlockProcess.with_block(prev_final_hash, &number/1)

    miners =
      blockquick_window(block)
      |> Enum.reverse()
      |> Enum.take(gap)

    # Iterating in reverse to find the most recent match
    Enum.reduce_while(miners, %{}, fn miner, scores ->
      if Map.values(scores) |> Enum.sum() > threshold do
        {:halt, true}
      else
        {:cont, Map.put(scores, miner, Map.get(window, miner, 0))}
      end
    end)
    |> case do
      true -> block
      _too_low_scores -> prev_final_hash
    end
  end

  @spec miner(Chain.Block.t()) :: Wallet.t()
  def miner(%Block{coinbase: nil, header: header}) do
    Header.recover_miner(header)
  end

  def miner(%Block{coinbase: coinbase, header: header}) do
    case Wallet.pubkey(coinbase) do
      {:ok, _pub} -> coinbase
      {:error, nil} -> Header.recover_miner(header)
    end
  end

  @spec coinbase(Chain.Block.t()) :: non_neg_integer
  def coinbase(block = %Block{}) do
    miner(block) |> Wallet.address!() |> :binary.decode_unsigned()
  end

  @spec gas_limit(Block.t()) :: non_neg_integer()
  def gas_limit(%Block{} = _block) do
    Chain.gas_limit()
  end

  #########################################################
  ###### FUNCTIONS BELOW THIS LINE ARE STILL JUNK #########
  #########################################################

  @spec size(Block.t()) :: non_neg_integer()
  def size(%Block{} = block) do
    # TODO, needs fixed external format
    byte_size(:erlang.term_to_binary(export(block)))
  end

  @spec logs_bloom(Block.t()) :: <<_::528>>
  def logs_bloom(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  @spec extra_data(Block.t()) :: <<_::528>>
  def extra_data(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  @spec receipts_root(Block.t()) :: <<_::528>>
  def receipts_root(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end
end
