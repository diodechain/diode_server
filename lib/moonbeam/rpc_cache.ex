defmodule Moonbeam.RPCCache do
  use GenServer
  require Logger
  alias Moonbeam.RPCCache

  defstruct [:lru, :block_number, :block_number_timestamp]

  def start_link([]) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__, hibernate_after: 5_000)
  end

  @impl true
  def init(nil) do
    {:ok, %__MODULE__{lru: Lru.new(1000), block_number: nil}}
  end

  def block_number() do
    GenServer.call(__MODULE__, :block_number)
  end

  def get_block_by_number(block \\ "latest", with_transactions \\ false) do
    block =
      if block == "latest" do
        block_number()
      else
        block
      end

    get("eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(address, slot, block \\ "latest") do
    block =
      if block == "latest" do
        block_number()
      else
        block
      end

    get("eth_getStorageAt", [address, slot, block])
  end

  def get(method, args) do
    GenServer.call(__MODULE__, {:get, method, args})
  end

  @impl true
  def handle_call(:block_number, _from, state = %RPCCache{block_number: nil}) do
    number = Moonbeam.block_number()
    time = System.os_time(:second)
    {:reply, number, %RPCCache{state | block_number: number, block_number_timestamp: time}}
  end

  def handle_call(
        :block_number,
        _from,
        state = %RPCCache{block_number: number, block_number_timestamp: time}
      ) do
    now = System.os_time(:second)

    if now - time > 5 do
      number = Moonbeam.block_number()
      {:reply, number, %RPCCache{state | block_number: number, block_number_timestamp: now}}
    else
      {:reply, number, state}
    end
  end

  def handle_call({:get, method, args}, _from, state = %RPCCache{lru: lru}) do
    {lru, ret} = Lru.fetch(lru, {method, args}, fn -> Moonbeam.rpc!(method, args) end)
    {:reply, ret, %RPCCache{state | lru: lru}}
  end
end
