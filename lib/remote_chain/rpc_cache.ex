# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPCCache do
  use GenServer, restart: :permanent
  require Logger
  alias RemoteChain.NodeProxy
  alias RemoteChain.RPCCache

  defstruct [:chain, :lru, :block_number]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: name(chain), hibernate_after: 5_000)
  end

  @impl true
  def init(chain) do
    {:ok, %__MODULE__{chain: chain, lru: Lru.new(1000), block_number: nil}}
  end

  def set_block_number(chain, block_number) do
    GenServer.cast(name(chain), {:block_number, block_number})
  end

  def block_number(chain) do
    case GenServer.call(name(chain), :block_number) do
      nil -> raise "no block_number yet"
      number -> number
    end
  end

  def get_block_by_number(chain, block \\ "latest", with_transactions \\ false) do
    block = resolve_block(chain, block)
    get(chain, "eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(chain, address, slot, block \\ "latest") do
    block = resolve_block(chain, block)
    get(chain, "eth_getStorageAt", [address, slot, block])
  end

  def get_code(chain, address, block \\ "latest") do
    get(chain, "eth_getCode", [address, block])
  end

  def get_transaction_count(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    get(chain, "eth_getTransactionCount", [address, block])
  end

  def get_balance(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    get(chain, "eth_getBalance", [address, block])
  end

  def get(chain, method, args) do
    case GenServer.call(name(chain), {:get, method, args}) do
      nil -> maybe_cache(chain, method, args)
      result -> result
    end
  end

  @impl true
  def handle_cast({:block_number, block_number}, state) do
    {:noreply, %RPCCache{state | block_number: block_number}}
  end

  def handle_cast({:set, method, args, result}, state = %RPCCache{lru: lru}) do
    {:noreply, %RPCCache{state | lru: Lru.insert(lru, {method, args}, result)}}
  end

  @impl true
  def handle_call(:block_number, _from, state = %RPCCache{block_number: number}) do
    {:reply, number, state}
  end

  def handle_call({:get, method, args}, _from, state = %RPCCache{lru: lru}) do
    {:reply, Lru.get(lru, {method, args}), state}
  end

  defp resolve_block(chain, "latest"), do: block_number(chain)
  defp resolve_block(_chain, block), do: block

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain) || raise "no chainimpl for #{inspect(chain)}"
    {:global, {__MODULE__, impl}}
  end

  defp maybe_cache(chain, method, args) do
    {time, ret} = :timer.tc(fn -> NodeProxy.rpc!(chain, method, args) end)
    Logger.debug("RPC #{method} #{inspect(args)} took #{div(time, 1000)}ms")

    if should_cache_method(method, args) and should_cache_result(ret) do
      GenServer.cast(name(chain), {:set, method, args, ret})
    end

    ret
  end

  defp should_cache_method("dio_edgev2", [hex]) do
    case hd(Rlp.decode!(Base16.decode(hex))) do
      true ->
        true

      _other ->
        # IO.inspect(other, label: "should_cache_method dio_edgev2")
        true
    end
  end

  defp should_cache_method(_method, _args) do
    # IO.inspect({method, args}, label: "should_cache_method")
    true
  end

  defp should_cache_result(_ret) do
    # IO.inspect(ret, label: "should_cache_result")
    true
  end
end
