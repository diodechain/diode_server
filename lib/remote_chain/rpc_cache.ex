# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPCCache do
  use GenServer, restart: :permanent
  require Logger
  alias RemoteChain.NodeProxy
  alias RemoteChain.RPCCache
  @default_timeout 25_000

  defstruct [:chain, :lru, :block_number, :request_rpc, :request_from, :request_collection]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: name(chain), hibernate_after: 5_000)
  end

  @impl true
  def init(chain) do
    {:ok,
     %__MODULE__{
       chain: chain,
       lru: Lru.new(100_000),
       block_number: nil,
       request_rpc: %{},
       request_from: %{},
       request_collection: :gen_server.reqids_new()
     }}
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
    rpc!(chain, "eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(chain, address, slot, block \\ "latest") do
    block = resolve_block(chain, block)

    # for storage requests we use the last change block as the base
    # any contract not using change tracking will suffer 240 blocks (one hour) of caching
    block =
      case get_last_change(chain, address, block) do
        0 -> block - rem(block, 240)
        num -> min(num, block)
      end

    rpc!(chain, "eth_getStorageAt", [address, slot, block])
  end

  def get_storage_many(chain, address, slots, block \\ "latest") do
    block = resolve_block(chain, block)

    # for storage requests we use the last change block as the base
    # any contract not using change tracking will suffer 240 blocks (one hour) of caching
    block =
      case get_last_change(chain, address, block) do
        0 -> block - rem(block, 240)
        num -> min(num, block)
      end

    calls = Enum.map(slots, fn slot -> {:rpc, "eth_getStorageAt", [address, slot, block]} end)

    RemoteChain.Util.batch_call(name(chain), calls, @default_timeout)
    |> Enum.map(fn
      {:reply, %{"result" => result}} ->
        result

      {:reply, %{"error" => error}} ->
        raise "RPC error in get_storage_many(#{inspect({chain, address, slots, block})}): #{inspect(error)}"

      {:error, reason} ->
        raise "Batch error in get_storage_many(#{inspect({chain, address, slots, block})}): #{inspect(reason)}"

      :timeout ->
        raise "Timeout error in get_storage_many(#{inspect({chain, address, slots, block})})"
    end)
  end

  def get_code(chain, address, block \\ "latest") do
    rpc!(chain, "eth_getCode", [address, block])
  end

  def get_transaction_count(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getTransactionCount", [address, block])
  end

  def get_balance(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getBalance", [address, block])
  end

  def get_last_change(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)

    # `ChangeTracker.sol` slot for signaling: 0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487
    rpc!(chain, "eth_getStorageAt", [
      address,
      "0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487",
      block
    ])
    |> Base16.decode_int()
  end

  def get_account_root(chain, address, block \\ "latest")
      when chain in [Chains.MoonbaseAlpha, Chains.Moonbeam, Chains.Moonriver] do
    block = resolve_block(chain, block)
    # this code is specific to Moonbeam (EVM on Substrate) simulating the account_root
    # we're now using the `ChangeTracker.sol` slot for signaling: 0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487

    last_change = get_last_change(chain, address, block)

    if last_change > 0 do
      Hash.keccak_256(address <> "#{last_change}")
    else
      # there is no change tracking yet?
      # in this case we're just not updating more often than once an hour
      blocks_per_hour = div(3600, 15)
      base = div(block + Base16.decode_int(address), blocks_per_hour)
      Hash.keccak_256(address <> "#{last_change}:#{base}")
    end
    |> Base16.encode()
  end

  def rpc!(chain, method, params) do
    %{"result" => ret} = rpc(chain, method, params)
    ret
  end

  def rpc(chain, method, params) do
    GenServer.call(name(chain), {:rpc, method, params}, @default_timeout)
  end

  @impl true
  def handle_cast({:block_number, block_number}, state) do
    {:noreply, %RPCCache{state | block_number: block_number}}
  end

  @impl true
  def handle_call(:block_number, _from, state = %RPCCache{block_number: number}) do
    {:reply, number, state}
  end

  def handle_call(
        {:rpc, method, params},
        from,
        state = %RPCCache{
          chain: chain,
          lru: lru,
          request_rpc: request_rpc,
          request_collection: col
        }
      ) do
    case Lru.get(lru, {method, params}) do
      nil ->
        case Map.get(request_rpc, {method, params}) do
          nil ->
            col =
              :gen_server.send_request(
                NodeProxy.name(chain),
                {:rpc, method, params},
                {method, params},
                col
              )

            request_rpc = Map.put(request_rpc, {method, params}, MapSet.new([from]))
            {:noreply, %RPCCache{state | request_rpc: request_rpc, request_collection: col}}

          set ->
            request_rpc = Map.put(request_rpc, {method, params}, MapSet.put(set, from))
            {:noreply, %RPCCache{state | request_rpc: request_rpc}}
        end

      result ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info(
        msg,
        state = %RPCCache{
          lru: lru,
          chain: chain,
          request_collection: col,
          request_rpc: request_rpc
        }
      ) do
    case :gen_server.check_response(msg, col, true) do
      :no_request ->
        Logger.info("#{__MODULE__}(#{chain}) received no_request: #{inspect(msg)}")
        {:noreply, state}

      :no_reply ->
        Logger.info("#{__MODULE__}(#{chain}) received no_reply: #{inspect(msg)}")
        {:noreply, state}

      {ret, {method, params}, col} ->
        {state, ret} =
          case ret do
            {:reply, ret} ->
              state =
                if should_cache_method(method, params) and should_cache_result(ret) do
                  %RPCCache{state | lru: Lru.insert(lru, {method, params}, ret)}
                else
                  state
                end

              {state, ret}

            {:error, _reason} ->
              {state, ret}
          end

        {froms, request_rpc} = Map.pop!(request_rpc, {method, params})
        for from <- froms, do: GenServer.reply(from, ret)
        state = %RPCCache{state | request_collection: col, request_rpc: request_rpc}
        {:noreply, state}
    end
  end

  def resolve_block(chain, "latest"), do: block_number(chain)
  def resolve_block(_chain, block) when is_integer(block), do: block
  def resolve_block(_chain, "0x" <> _ = block), do: Base16.decode_int(block)

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end

  defp should_cache_method("dio_edgev2", [hex]) do
    case hd(Rlp.decode!(Base16.decode(hex))) do
      "ticket" ->
        false

      _other ->
        # IO.inspect(other, label: "should_cache_method dio_edgev2")
        true
    end
  end

  defp should_cache_method(_method, _args) do
    # IO.inspect({method, params}, label: "should_cache_method")
    true
  end

  defp should_cache_result(_ret) do
    # IO.inspect(ret, label: "should_cache_result")
    true
  end
end
