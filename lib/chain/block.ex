defmodule Chain.Block do
  alias Chain.{Block, BlockCache, State, Transaction, Header}

  defstruct transactions: [], header: %Chain.Header{}, receipts: []

  @type t :: %Chain.Block{
          transactions: [Chain.Transaction.t()],
          header: Chain.Header.t(),
          receipts: [Chain.TransactionReceipt.t()]
        }

  # @min_difficulty 131072
  @min_difficulty 65536
  @max_difficulty 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  def header(%Block{header: header}), do: header
  def txhash(%Block{header: header}), do: header.transaction_hash

  def parent(%Block{} = block), do: Chain.block_by_hash(parent_hash(block))
  def parent_hash(%Block{header: header}), do: header.previous_block
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
         {7, simBlock} <- {7, simulate(block)},
         {8, true} <- {8, state_hash(simBlock) == state_hash(block)} do
      simBlock
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
    blockRef = Block.parent(block)

    # Calculating stake weight as
    # ( stake / 1000 )²  but no less than 1
    #
    # For two decimal accuracy we calculcate in two steps:
    # (( stake / 100 )² * max_diff) / (10² * difficulty_block)
    #
    stake =
      Chain.Registry.minerValue(0, Block.miner(block), blockRef)
      |> div(Shell.ether(100))
      |> max(10)

    Hash.integer(hash) < div(stake * stake * @max_difficulty, 100 * difficulty(block))
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

  @spec sign(Block.t(), Wallet.t(), nil | binary()) :: Block.t()
  def sign(%Block{} = block, miner, nonce \\ nil) do
    header =
      header(block)
      |> Header.sign(miner, nonce)
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

  @spec totalDifficulty(Block.t()) :: non_neg_integer()
  def totalDifficulty(%Block{} = block) do
    parent = Block.parent(block)

    if parent == nil do
      Block.difficulty(block)
    else
      BlockCache.totalDifficulty(parent) + Block.difficulty(block)
    end
  end

  @spec number(Block.t()) :: non_neg_integer()
  def number(nil) do
    0
  end

  def number(%Block{} = block) do
    BlockCache.number(BlockCache.parent(block)) + 1
  end

  @spec gasPrice(Chain.Block.t()) :: non_neg_integer()
  def gasPrice(%Block{} = block) do
    price =
      Enum.reduce(transactions(block), nil, fn tx, price ->
        if price == nil or price > Transaction.gasPrice(tx) do
          Transaction.gasPrice(tx)
        else
          price
        end
      end)

    if price == nil do
      0
    end

    price
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
      :revert -> 0
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

  @spec nonce(Block.t()) :: non_neg_integer()
  def nonce(%Block{} = _block) do
    0x1000000000000000
  end

  def coinbase(%Block{} = block) do
    miner(block) |> Wallet.address!() |> :binary.decode_unsigned()
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
