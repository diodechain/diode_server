defmodule Chain.BlockCache do
  alias Chain.Block
  use GenServer

  defstruct difficulty: 0, totalDifficulty: 0, number: -1, receipts: [], epoch: 0

  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :compressed, :public])
    {:ok, __MODULE__}
  end

  def handle_call({:do_cache, block}, _from, state) do
    {:reply, cache(block), state}
  end

  def reset() do
    :ets.delete_all_objects(__MODULE__)
  end

  def create_cache(block) do
    %Chain.BlockCache{
      difficulty: Block.difficulty(block),
      totalDifficulty: Block.totalDifficulty(block),
      number: Block.number(block),
      receipts: Block.receipts(block),
      epoch: Block.epoch(block)
    }
  end

  def cache(nil) do
    %Chain.BlockCache{}
  end

  def cache(block) do
    hash = Block.hash(block)

    case :ets.lookup(__MODULE__, Block.hash(block)) do
      [{^hash, cache}] ->
        cache

      [] ->
        if :erlang.whereis(__MODULE__) == self() do
          # :io.format("miss: ~p~n", [Base16.encode(hash)])
          cache = create_cache(block)
          :ets.insert(__MODULE__, {hash, cache})
          cache
        else
          GenServer.call(__MODULE__, {:do_cache, block}, 20_000)
        end
    end
  end

  def difficulty(block) do
    cache(block).difficulty
  end

  def totalDifficulty(block) do
    cache(block).totalDifficulty
  end

  def number(block) do
    cache(block).number
  end

  def receipts(block) do
    cache(block).receipts
  end

  def epoch(block) do
    cache(block).epoch
  end

  #########################################################
  ####################### DELEGATES #######################
  #########################################################

  defdelegate coinbase(block), to: Block
  defdelegate create(parent, transactions, miner, time, trace? \\ false), to: Block
  defdelegate encode_transactions(transactions), to: Block
  defdelegate extraData(block), to: Block
  defdelegate gasLimit(block), to: Block
  defdelegate gasPrice(block), to: Block
  defdelegate gasUsed(block), to: Block
  defdelegate hash(block), to: Block
  defdelegate hash_in_target?(block, hash), to: Block
  defdelegate hash_target(block), to: Block
  defdelegate hash_valid?(block), to: Block
  defdelegate header(block), to: Block
  defdelegate increment_nonce(block), to: Block
  defdelegate logs(block), to: Block
  defdelegate logsBloom(block), to: Block
  defdelegate miner(block), to: Block
  defdelegate nonce(block), to: Block
  defdelegate parent(block), to: Block
  defdelegate parent_hash(block), to: Block
  defdelegate receiptsRoot(block), to: Block
  defdelegate sign(block, priv), to: Block
  defdelegate simulate(block, trace? \\ false), to: Block
  defdelegate size(block), to: Block
  defdelegate state(block), to: Block
  defdelegate state_hash(block), to: Block
  defdelegate timestamp(block), to: Block
  defdelegate transactionGas(block, transaction), to: Block
  defdelegate transactionIndex(block, transaction), to: Block
  defdelegate transactionOut(block, transaction), to: Block
  defdelegate transactions(block), to: Block
  defdelegate transactionStatus(block, transaction), to: Block
  defdelegate txhash(block), to: Block
  defdelegate validate(block), to: Block
  defdelegate valid?(block), to: Block
end
