# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPCCache do
  use GenServer, restart: :permanent
  require Logger
  alias RemoteChain.Cache
  alias RemoteChain.NodeProxy
  alias RemoteChain.RPCCache
  @default_timeout 25_000

  defstruct [
    :chain,
    :cache,
    :block_number,
    :request_rpc,
    :request_from,
    :request_collection,
    :block_number_requests
  ]

  def start_link([chain, cache]) do
    GenServer.start_link(__MODULE__, {chain, cache}, name: name(chain), hibernate_after: 5_000)
  end

  @impl true
  def init({chain, cache}) do
    {:ok,
     %__MODULE__{
       chain: chain,
       cache: cache,
       block_number: nil,
       request_rpc: %{},
       request_from: %{},
       request_collection: :gen_server.reqids_new(),
       block_number_requests: []
     }}
  end

  def optimistic_caching?() do
    :persistent_term.get({__MODULE__, :optimistic_caching}, true)
  end

  def set_optimistic_caching(bool) do
    :persistent_term.put({__MODULE__, :optimistic_caching}, bool)
  end

  def block_number(chain) do
    case GenServer.call(name(chain), :block_number) do
      number when number != nil -> number
    end
  end

  def get_block_by_number(chain, block \\ "latest", with_transactions \\ false) do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getBlockByNumber", [block, with_transactions])
  end

  # Retrieves all storage slots for an address, only available on Diode
  def get_storage(chain, address, block \\ "latest")
      when chain in [Chains.Diode, Chains.DiodeDev, Chains.DiodeStaging] do
    block = resolve_block(chain, block)

    # for storage requests we use the last change block as the base
    # any contract not using change tracking will suffer 240 blocks (one hour) of caching
    block = get_last_change(chain, address, block)
    rpc!(chain, "eth_getStorage", [address, Base16.encode(block, false)])
  end

  def get_storage_at(chain, address, slot, block \\ "latest") do
    block = resolve_block(chain, block)

    # for storage requests we use the last change block as the base
    # any contract not using change tracking will suffer 240 blocks (one hour) of caching
    block = get_last_change(chain, address, block)
    rpc!(chain, "eth_getStorageAt", [address, slot, Base16.encode(block, false)])
  end

  def get_storage_many(chain, address, slots, block \\ "latest") do
    block = resolve_block(chain, block)

    # for storage requests we use the last change block as the base
    # any contract not using change tracking will suffer 240 blocks (one hour) of caching
    block = get_last_change(chain, address, block)

    calls =
      Enum.map(slots, fn slot ->
        {:rpc, "eth_getStorageAt", [address, slot, Base16.encode(block, false)]}
      end)

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

  def call(chain, to, from, data, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_call", [%{to: to, data: data, from: from}, Base16.encode(block, false)])
  end

  def get_code(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getCode", [address, Base16.encode(block, false)])
  end

  def get_transaction_count(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getTransactionCount", [address, Base16.encode(block, false)])
  end

  def get_balance(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getBalance", [address, Base16.encode(block, false)])
  end

  def get_last_change(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)

    if chain in [Chains.Diode, Chains.DiodeDev, Chains.DiodeStaging] do
      case GenServer.call(name(chain), {:cache, {:last_change_block, block}}) do
        nil ->
          root =
            get_account_root(chain, address, block)

          case GenServer.call(name(chain), {:cache, {:last_change_root, root}}) do
            nil ->
              GenServer.cast(name(chain), {:set_cache, {:last_change_root, root}, block})
              GenServer.cast(name(chain), {:set_cache, {:last_change_block, block}, block})
              block

            block ->
              GenServer.cast(name(chain), {:set_cache, {:last_change_block, block}, block})

              block
          end

        block ->
          block
      end
    else
      # Assuming 12s block time for moonbeam
      blocks_per_hour = div(3600, 12)

      # `ChangeTracker.sol` slot for signaling: 0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487
      rpc!(chain, "eth_getStorageAt", [
        address,
        "0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487",
        Base16.encode(block, false)
      ])
      |> Base16.decode_int()
      |> case do
        0 -> block - rem(block, blocks_per_hour)
        num -> max(min(num, block), block - blocks_per_hour)
      end
    end
  end

  def get_account_root(chain, address, block \\ "latest")

  def get_account_root(chain, address, block)
      when chain in [Chains.Diode, Chains.DiodeDev, Chains.DiodeStaging] do
    block = resolve_block(chain, block)
    msg = Rlp.encode!(["getaccount", block, Base16.decode(address)]) |> Base16.encode()

    ["response", ret, _proofs] =
      rpc!(chain, "dio_edgev2", [msg])
      |> Base16.decode()
      |> Rlp.decode!()

    ret
    |> Rlpx.list2map()
    |> Map.get("storage_root") || throw("No storage_root in account")
  end

  def get_account_root(chain, address, block)
      when chain in [Chains.MoonbaseAlpha, Chains.Moonbeam, Chains.Moonriver] do
    block = resolve_block(chain, block)
    # this code is specific to Moonbeam (EVM on Substrate) simulating the account_root
    # we're now using the `ChangeTracker.sol` slot for signaling: 0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487

    last_change = get_last_change(chain, address, block)

    Hash.keccak_256(address <> "#{last_change}")
    |> Base16.encode()
  end

  def rpc!(chain, method, params) do
    case rpc(chain, method, params) do
      %{"result" => ret} ->
        ret

      other ->
        raise "RPC error in #{inspect(chain)}.#{method}(#{inspect(params)}): #{inspect(other)}"
    end
  end

  def rpc(chain, method, params) do
    GenServer.call(name(chain), {:rpc, method, params}, @default_timeout)
  end

  @impl true
  def handle_call(
        :block_number,
        from,
        state = %RPCCache{block_number: nil, block_number_requests: requests}
      ) do
    {:noreply, %RPCCache{state | block_number_requests: [from | requests]}}
  end

  def handle_call(:block_number, _from, state = %RPCCache{block_number: number}) do
    {:reply, number, state}
  end

  def handle_call({:rpc, method, params}, from, state = %RPCCache{chain: chain, cache: cache}) do
    case Cache.get(cache, {chain, method, params}) do
      nil ->
        {:noreply, send_request(method, params, from, state)}

      result ->
        if :rand.uniform() < 0.1 do
          {:reply, result, send_request(method, params, nil, state)}
        else
          {:reply, result, state}
        end
    end
  end

  def handle_call({:cache, key}, _from, state = %RPCCache{chain: chain, cache: cache}) do
    {:reply, Cache.get(cache, {chain, key}), state}
  end

  @impl true
  def handle_cast({:set_cache, key, value}, state = %RPCCache{chain: chain, cache: cache}) do
    cache = Cache.put(cache, {chain, key}, value)
    {:noreply, %RPCCache{state | cache: cache}}
  end

  defp send_request(method, params, from, state = %RPCCache{request_rpc: request_rpc}) do
    now = System.os_time(:second)

    case Map.get(request_rpc, {method, params}) do
      nil ->
        new_request(method, params, from, state)

      {time, _set} when now - time > @default_timeout ->
        new_request(method, params, from, state)

      {time, set} ->
        request_rpc = Map.put(request_rpc, {method, params}, {time, MapSet.put(set, from)})
        %RPCCache{state | request_rpc: request_rpc}
    end
  end

  defp new_request(
         method,
         params,
         from,
         state = %RPCCache{chain: chain, request_rpc: request_rpc, request_collection: col}
       ) do
    col =
      :gen_server.send_request(
        NodeProxy.name(chain),
        {:rpc, method, params},
        {method, params},
        col
      )

    now = System.os_time(:second)
    request_rpc = Map.put(request_rpc, {method, params}, {now, MapSet.new([from])})
    %RPCCache{state | request_rpc: request_rpc, request_collection: col}
  end

  @impl true
  def handle_info(
        {{NodeProxy, _chain}, :block_number, block_number},
        state = %RPCCache{block_number_requests: requests, chain: chain}
      ) do
    for from <- requests do
      GenServer.reply(from, block_number)
    end

    # for development nodes we need to ensure block_number > 0 (genesis)
    # to prevent block-reorgs from causing issues we're doing 5 blocks delay
    if optimistic_caching?() and block_number > 5 do
      block_number = block_number - 5

      spawn(fn ->
        if chain in [Chains.Diode, Chains.DiodeDev, Chains.DiodeStaging] do
          rpc(chain, "dio_edgev2", [Base16.encode(Rlp.encode!(["getblockheader2", block_number]))])
        end

        get_block_by_number(chain, block_number)
      end)
    end

    {:noreply, %RPCCache{state | block_number: block_number, block_number_requests: []}}
  end

  def handle_info(
        msg,
        state = %RPCCache{
          cache: cache,
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
                  %RPCCache{state | cache: Cache.put(cache, {chain, method, params}, ret)}
                else
                  state
                end

              {state, ret}

            {:error, _reason} ->
              {state, ret}
          end

        {{_time, froms}, request_rpc} = Map.pop!(request_rpc, {method, params})

        for from <- froms do
          if from != nil, do: GenServer.reply(from, ret)
        end

        state = %RPCCache{state | request_collection: col, request_rpc: request_rpc}
        {:noreply, state}
    end
  end

  def resolve_block(chain, "latest"), do: block_number(chain)
  def resolve_block(_chain, block) when is_integer(block), do: block
  def resolve_block(_chain, "0x" <> _ = block), do: Base16.decode_int(block)

  defp name(nil), do: raise("Chain `nil` not found")

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end

  defp should_cache_method("dio_edgev2", [hex]) do
    case hd(Rlp.decode!(Base16.decode(hex))) do
      "ticket" -> false
      _other -> true
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
