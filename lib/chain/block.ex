defmodule Chain.Block do
  alias Chain.{Block, BlockCache, State, Transaction, Header}

  defstruct transactions: [], header: %Chain.Header{}, receipts: []

  @type t :: %Chain.Block{
          transactions: [Chain.Transaction.t()],
          header: Chain.Header.t(),
          receipts: [Chain.transaction_receipt.t()]
        }

  # @min_difficulty 131072
  @min_difficulty 65536
  @max_difficulty 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  def header(%Block{header: header}), do: header
  def txhash(%Block{header: header}), do: header.transaction_hash

  def parent(%Block{} = block), do: Chain.block_by_hash(parent_hash(block))
  def parent_hash(%Block{header: header}), do: header.previous_block
  def nonce(%Block{header: header}), do: header.nonce
  def miner(%Block{header: header}), do: Header.miner(header)
  @spec state(Chain.Block.t()) :: Chain.State.t()
  def state(%Block{} = block), do: Chain.state_load(state_hash(block))
  def state_hash(%Block{header: header}), do: header.state_hash
  @spec hash(Chain.Block.t()) :: binary()
  def hash(%Block{header: header}), do: header.block_hash
  @spec transactions(Chain.Block.t()) :: [Chain.Transaction.t()]
  def transactions(%Block{transactions: transactions}), do: transactions
  @spec timestamp(Chain.Block.t()) :: non_neg_integer()
  def timestamp(%Block{header: header}), do: header.timestamp
  def receipts(%Block{receipts: receipts}), do: receipts

  @spec valid?(any()) :: boolean()
  def valid?(block) do
    case validate(block) do
      %Chain.Block{} -> true
      _ -> false
    end
  end

  @spec validate(any()) :: %Chain.Block{} | {non_neg_integer(), any()}
  def validate(block) do
    with {1, %Block{}} <- {1, block},
         {2, %Block{}} <- {2, parent(block)},
         {3, true} <-
           {3, Wallet.equal?(Header.miner(block.header), Header.recover_miner(block.header))},
         {4, true} <- {4, hash_valid?(block)},
         {5, []} <-
           {5,
            Enum.map(transactions(block), &Transaction.validate/1)
            |> Enum.reject(fn tx -> tx == true end)},
         {6, true} <- {6, Diode.hash(encode_transactions(transactions(block))) == txhash(block)},
         {7, sim_block} <- {7, simulate(block)},
         {8, true} <- {8, state_hash(sim_block) == state_hash(block)} do
      %{block | receipts: sim_block.receipts}
    else
      {nr, error} -> {nr, error}
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
    Hash.integer(hash) < BlockCache.hash_target(block)
  end

  @spec hash_target(Chain.Block.t()) :: integer
  def hash_target(block) do
    block_ref = Block.parent(block)

    # Calculating stake weight as
    # ( stake / 1000 )²  but no less than 1
    #
    # For two decimal accuracy we calculcate in two steps:
    # (( stake / 100 )² * max_diff) / (10² * difficulty_block)
    #
    stake =
      if block_ref == nil do
        1
      else
        Contract.Registry.miner_value(0, Block.miner(block), block_ref)
        |> div(Shell.ether(100))
        |> max(10)
      end

    div(stake * stake * @max_difficulty, 100 * Block.difficulty(block))
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
    header = %Header{
      previous_block: hash(parent),
      timestamp: time,
      miner_pubkey: Wallet.pubkey!(miner)
    }

    block = %Block{
      header: header
    }

    {nstate, transactions, receipts} =
      Enum.reduce(transactions, {state(parent), [], []}, fn %Transaction{} = tx,
                                                            {%State{} = state, txs, rcpts} ->
        case Transaction.apply(tx, block, state, trace?) do
          {:ok, state, rcpt} ->
            {state, txs ++ [tx], rcpts ++ [rcpt]}

          {:error, message} ->
            :io.format("Error in transaction: ~p (~p)~n", [message, Transaction.hash(tx)])
            {state, txs, rcpts}
        end
      end)

    state_hash =
      Chain.state_store(nstate)
      |> State.hash()

    header = %Header{
      header
      | state_hash: state_hash,
        transaction_hash: Diode.hash(encode_transactions(transactions))
    }

    %Block{block | transactions: transactions, header: header, receipts: receipts}
  end

  @spec encode_transactions(any()) :: binary()
  def encode_transactions(transactions) do
    BertExt.encode!(Enum.map(transactions, &Transaction.to_rlp/1))
  end

  @spec simulate(Chain.Block.t(), true | false) :: Chain.Block.t()
  def simulate(%Block{} = block, trace? \\ false) do
    parent =
      if Block.number(block) >= 1 do
        %Block{} = parent(block)
      else
        Chain.GenesisFactory.testnet_parent()
      end

    create(parent, transactions(block), miner(block), timestamp(block), trace?)
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

  @spec difficulty(Block.t()) :: non_neg_integer()
  def difficulty(%Block{} = block) do
    if Diode.dev_mode?() do
      1
    else
      do_difficulty(block)
    end
  end

  defp do_difficulty(%Block{} = block) do
    parent = BlockCache.parent(block)

    if parent == nil do
      @min_difficulty
    else
      delta = BlockCache.timestamp(block) - BlockCache.timestamp(parent)
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

  @spec total_difficulty(Block.t()) :: non_neg_integer()
  def total_difficulty(%Block{} = block) do
    parent = Block.parent(block)

    if parent == nil do
      Block.difficulty(block)
    else
      BlockCache.total_difficulty(parent) + Block.difficulty(block)
    end
  end

  @spec number(Block.t()) :: non_neg_integer()
  def number(nil) do
    0
  end

  def number(%Block{} = block) do
    BlockCache.number(BlockCache.parent(block)) + 1
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
    Contract.Registry.epoch(block)
  end

  @spec gas_used(Block.t()) :: non_neg_integer()
  def gas_used(%Block{} = block) do
    Enum.reduce(receipts(block), 0, fn receipt, acc -> acc + receipt.gas_used end)
  end

  @spec transaction_receipt(Chain.Block.t(), Chain.Transaction.t()) ::
          Chain.transaction_receipt.t()
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
      :revert -> 0
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
          "transaction_index" => Block.transaction_index(block, tx),
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

  #########################################################
  ###### FUNCTIONS BELOW THIS LINE ARE STILL JUNK #########
  #########################################################

  @spec size(Block.t()) :: non_neg_integer()
  def size(%Block{} = block) do
    # TODO, needs fixed external format
    byte_size(BertInt.encode!(block))
  end

  @spec logs_bloom(Block.t()) :: <<_::528>>
  def logs_bloom(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  def coinbase(%Block{} = block) do
    miner(block) |> Wallet.address!() |> :binary.decode_unsigned()
  end

  @spec gas_limit(Block.t()) :: non_neg_integer()
  def gas_limit(%Block{} = _block) do
    Chain.gas_limit()
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
