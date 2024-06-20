# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.NodeProxy do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use GenServer, restart: :permanent
  alias RemoteChain.RPCCache
  alias RemoteChain.NodeProxy
  require Logger
  @default_timeout 25_000

  defstruct [
    :chain,
    connections: %{},
    req: 100,
    requests: %{},
    lastblocks: %{},
    subscriptions: %{}
  ]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, %NodeProxy{chain: chain, connections: %{}},
      name: name(chain)
    )
  end

  @impl true
  def init(state) do
    {:ok, ensure_connections(state)}
  end

  def rpc(chain, method, params) do
    GenServer.call(name(chain), {:rpc, method, params}, @default_timeout)
  end

  def subscribe_block(chain) do
    GenServer.cast(name(chain), {:subscribe_block, self()})
  end

  def unsubscribe_block(chain) do
    GenServer.cast(name(chain), {:unsubscribe_block, self()})
  end

  @impl true
  def handle_call({:rpc, method, params}, from, state) do
    state = ensure_connections(state)
    conn = Enum.random(Map.values(state.connections))
    id = state.req + 1

    request =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      }
      |> Poison.encode!()

    WebSockex.cast(conn, {:send_request, request})

    {:noreply,
     %{
       state
       | req: id,
         requests:
           Map.put(state.requests, id, %{
             from: from,
             method: method,
             params: params,
             start_ms: System.os_time(:millisecond),
             conn: conn
           })
     }}
  end

  @impl true
  def handle_cast(:ensure_connections, state) do
    {:noreply, ensure_connections(state)}
  end

  def handle_cast({:subscribe_block, pid}, state = %NodeProxy{subscriptions: subs}) do
    if Map.has_key?(subs, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      {:noreply, %{state | subscriptions: Map.put(subs, pid, ref)}}
    end
  end

  def handle_cast({:unsubscribe_block, pid}, state = %NodeProxy{subscriptions: subs}) do
    Process.demonitor(subs[pid])
    {:noreply, %{state | subscriptions: Map.delete(subs, pid)}}
  end

  @security_level 1
  @impl true
  def handle_info(
        {:new_block, ws_url, block_number},
        state = %NodeProxy{chain: chain, lastblocks: lastblocks, subscriptions: subs}
      ) do
    lastblocks = Map.put(lastblocks, ws_url, block_number)

    if Enum.count(lastblocks, fn {_, block} -> block == block_number end) >= @security_level do
      send(
        :global.whereis_name({RPCCache, chain}),
        {{__MODULE__, chain}, :block_number, block_number}
      )

      for {pid, _ref} <- subs do
        # RemoteChain.RPCCache.set_block_number(chain, block_number)
        send(pid, {{__MODULE__, chain}, :block_number, block_number})
      end
    end

    {:noreply, %{state | lastblocks: lastblocks}}
  end

  def handle_info(
        {:DOWN, _ref, :process, down_pid, reason},
        state = %{connections: connections, subscriptions: subs}
      ) do
    if Map.has_key?(subs, down_pid) do
      subs = Map.delete(subs, down_pid)
      {:noreply, %{state | subscriptions: subs}}
    else
      if reason != :normal do
        Logger.warning(
          "WSConn #{inspect(down_pid)} of #{inspect(state.chain)} disconnected for #{inspect(reason)}"
        )
      end

      pid = self()

      Debouncer.immediate({__MODULE__, pid, :ensure_connections}, fn ->
        GenServer.cast(pid, :ensure_connections)
      end)

      requests =
        Enum.reject(state.requests, fn {_, %{conn: conn, from: from}} ->
          if conn == down_pid do
            GenServer.reply(from, {:error, :disconnect})
            true
          end
        end)
        |> Map.new()

      new_connections = Enum.filter(connections, fn {_, pid} -> pid != down_pid end) |> Map.new()
      {:noreply, %{state | connections: new_connections, requests: requests}}
    end
  end

  def handle_info({:response, _ws_url, %{"id" => id} = response}, state) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        Logger.warning("No request found for response: #{inspect(response)}")
        {:noreply, state}

      {%{from: from, start_ms: start_ms, method: method, params: params}, requests} ->
        time_ms = System.os_time(:millisecond) - start_ms

        if time_ms > 200 do
          params =
            if method == "dio_edgev2" do
              Base16.decode(hd(params)) |> Rlp.decode!()
            else
              params
            end

          Logger.debug("RPC #{method} #{inspect(params)} took #{time_ms}ms")
        end

        GenServer.reply(from, response)
        {:noreply, %{state | requests: requests}}
    end
  end

  defp ensure_connections(state = %NodeProxy{chain: chain, connections: connections})
       when map_size(connections) < @security_level do
    urls = MapSet.new(RemoteChain.ws_endpoints(chain))
    existing = MapSet.new(Map.keys(connections))
    new_urls = MapSet.difference(urls, existing)
    new_url = MapSet.to_list(new_urls) |> Enum.random()

    pid = RemoteChain.WSConn.start(self(), chain, new_url)
    Process.monitor(pid)
    state = %{state | connections: Map.put(connections, new_url, pid)}
    ensure_connections(state)
  end

  defp ensure_connections(state) do
    state
  end

  def name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end
end
