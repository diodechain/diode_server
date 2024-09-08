defmodule BlockProcess do
  alias Model.ChainSql
  alias Chain.Block
  require Logger

  use GenServer
  defstruct []

  def start_link() do
    GenServer.start_link(__MODULE__, %BlockProcess{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    EtsLru.new(__MODULE__, 300)
    EtsLru.new(__MODULE__.State, 150)
    {:ok, state}
  end

  def fetch(block_ref, methods) when is_list(methods) do
    with_block(block_ref, fn block ->
      Enum.map(methods, fn method -> apply(Block, method, [block]) end)
    end)
  end

  def cache_block(block) do
    EtsLru.put(__MODULE__, Block.hash(block), Block.strip_state(block))
    EtsLru.put(__MODULE__.State, Block.hash(block), Block.state(block))
  end

  def with_account_tree(block_ref, account_id, fun) do
    with_block(block_ref, fn block -> fun.(Block.account_tree(block, account_id)) end)
  end

  def with_account(block_ref, account_id, fun) do
    with_state(block_ref, fn state -> fun.(Chain.State.account(state, account_id)) end)
  end

  def with_state(block_ref, fun) do
    with_block(block_ref, fn block ->
      fetch_state(Block.hash(block))
    end)
    |> fun.()
  end

  def fetch_state(block_hash) do
    EtsLru.fetch(__MODULE__.State, block_hash, fn -> ChainSql.state(block_hash) end)
  end

  def with_block(<<block_hash::binary-size(32)>>, fun) do
    if not Chain.block_by_hash?(block_hash) do
      with_block(nil, fun)
    else
      EtsLru.fetch(__MODULE__, block_hash, fn ->
        Stats.tc(:sql_block_by_hash, fn ->
          Model.ChainSql.block_by_hash(block_hash)
        end)
      end)
      |> fun.()
    end
  end

  def with_block(%Block{} = block, fun), do: fun.(block)
  def with_block("latest", fun), do: with_block(Chain.peak(), fun)
  def with_block("pending", fun), do: Chain.Worker.with_candidate(fun)
  def with_block("earliest", fun), do: with_block(0, fun)
  def with_block(nil, fun), do: fun.(nil)

  def with_block(num, fun) when is_integer(num),
    do: with_block(Chain.blockhash(num), fun)

  def with_block(<<"0x", _rest::binary>> = ref, fun) do
    if byte_size(ref) >= 66 do
      # assuming it's a block hash
      with_block(Base16.decode(ref), fun)
    else
      # assuming it's a block index
      with_block(Base16.decode_int(ref), fun)
    end
  end
end
