# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Kademlia do
  @moduledoc """
    Kademlia.ex is in fact a K* implementation. K* star is a modified version of Kademlia
    using the same KBuckets scheme to keep track of which nodes to remember. But instead of
    using the XOR metric it is using geometric distance on a ring as node value distance.
    Node distance is symmetric on the ring.
  """
  use GenServer
  alias Network.PeerHandler
  alias Object.Server
  alias Model.KademliaSql
  @k 3
  @relay_factor 3
  @broadcast_factor 50
  @storage_file "kademlia2.etf"

  defstruct tasks: %{}, network: nil
  @type t :: %Kademlia{tasks: map(), network: KBuckets.t()}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  def ping(node_id) do
    rpc(find_node(node_id), [PeerHandler.ping()])
  end

  @doc """
    broadcast is used to broadcast self generated blocks/transactions through the network
  """
  def broadcast(msg) do
    GenServer.cast(__MODULE__, {:broadcast, msg})
  end

  @doc """
    relay is used to forward NEW received blocks/transactions further through the network
  """
  def relay(msg) do
    msg = [PeerHandler.publish(), msg]

    KBuckets.next(network())
    |> filter_online()
    |> Enum.take(@relay_factor)
    |> Enum.each(fn item -> rpcast(item, msg) end)
  end

  @doc """
    store/1 same as store/2 but usees Object.key/1 and Object.encode/1
  """
  def store(object) when is_tuple(object) do
    key = Object.key(object)
    value = Object.encode!(object)
    store(key, value)
  end

  @doc """
    store() stores the given key-value pair in the @k nodes
    that are closest to the key
  """
  def store(key, value) when is_binary(value) do
    nodes =
      find_nodes(key)
      |> Enum.take(@k)

    # :io.format("Storing #{value} at ~p as #{Base16.encode(key)}~n", [Enum.map(nearest, &port/1)])
    rpc(nodes, [PeerHandler.store(), hash(key), value])
  end

  @doc """
    find_value() is different from store() in that it might return
    an earlier result
  """
  def find_value(key) do
    key = hash(key)
    nodes = do_find_nodes(key, KBuckets.k(), PeerHandler.find_value())

    case nodes do
      {:value, value, visited} ->
        result = KBuckets.nearest_n(visited, key, KBuckets.k())
        insert_nodes(visited)

        # Ensuring local database doesn't have anything older or newer
        value =
          with local_ret when local_ret != nil <- KademliaSql.object(key),
               local_block <- Object.block_number(Object.decode!(local_ret)),
               value_block <- Object.block_number(Object.decode!(value)) do
            if local_block < value_block do
              KademliaSql.put_object(key, value)
              value
            else
              with true <- local_block > value_block,
                   nearest when nearest != nil <- Enum.at(result, 0) do
                # IO.puts("updating a #{Wallet.printable(nearest.node_id)}")
                rpcast(nearest, [PeerHandler.store(), key, local_ret])
              end

              local_ret
            end
          else
            _ -> value
          end

        # Kademlia logic: Writing found result to second nearest node
        with second_nearest when second_nearest != nil <- Enum.at(result, 1) do
          # IO.puts("updating b #{Wallet.printable(second_nearest.node_id)}")
          rpcast(second_nearest, [PeerHandler.store(), key, value])
        end

        value

      visited ->
        insert_nodes(visited)

        # We got nothing so far, trying local fallback
        local_ret = KademliaSql.object(key)

        if local_ret != nil do
          for node <- Enum.take(visited, 2) do
            # IO.puts("updating c #{Wallet.printable(node.node_id)}")
            rpcast(node, [PeerHandler.store(), key, local_ret])
          end
        end

        local_ret
    end
  end

  def find_node(address) do
    case find_nodes(address) do
      [] ->
        nil

      [first | _] ->
        case Wallet.address!(first.node_id) do
          ^address -> first
          _ -> nil
        end
    end
  end

  def find_nodes(key) do
    key = hash(key)
    visited = do_find_nodes(key, KBuckets.k(), PeerHandler.find_node())
    insert_nodes(visited)
    nearest_n(key, visited)
  end

  defp insert_nodes(visited) do
    call(fn _from, state ->
      network =
        Enum.reduce(visited, state.network, fn item, network ->
          if not KBuckets.member?(network, item) do
            KBuckets.insert_items(network, visited)
          else
            network
          end
        end)

      {:reply, :ok, %Kademlia{state | network: network}}
    end)

    visited
  end

  @doc """
  Retrieves for the target key either the last cached values or
  the nearest k entries from the KBuckets store
  """
  def find_node_lookup(key) do
    get_cached(&nearest_n/1, key)
  end

  def network() do
    call(fn _from, state -> {:reply, state.network, state} end)
  end

  @impl true
  def handle_call({:call, fun}, from, state) do
    fun.(from, state)
  end

  def handle_call({:append, key, value, _store_self}, _from, queue) do
    KademliaSql.append!(key, value)
    {:reply, :ok, queue}
  end

  @impl true
  def handle_info(:save, state) do
    spawn(fn -> Chain.store_file(Diode.data_dir(@storage_file), state) end)
    Process.send_after(self(), :save, 60_000)
    {:noreply, state}
  end

  def handle_info(:contact_seeds, state = %Kademlia{network: network}) do
    for seed <- Diode.seeds() do
      %URI{userinfo: node_id, host: address, port: port} = URI.parse(seed)

      id =
        case node_id do
          nil -> Wallet.new()
          str -> Wallet.from_address(Base16.decode(str))
        end

      Network.Server.ensure_node_connection(PeerHandler, id, address, port)
    end

    online = Network.Server.get_connections(PeerHandler)
    now = System.os_time(:second)

    network =
      KBuckets.to_list(network)
      |> Enum.reduce(network, fn item = %KBuckets.Item{node_id: node_id}, network ->
        if not Map.has_key?(online, Wallet.address!(node_id)) do
          if next_retry(item) < now, do: ensure_node_connection(item)
          network
        else
          KBuckets.update_item(network, %KBuckets.Item{item | last_connected: now})
        end
      end)

    Process.send_after(self(), :contact_seeds, 60_000)
    {:noreply, %{state | network: network}}
  end

  @impl true
  def handle_continue(:seed, state) do
    Process.send_after(self(), :save, 60_000)
    handle_info(:contact_seeds, state)
    {:noreply, state}
  end

  # Private call used by PeerHandler when connections are established
  @impl true
  def handle_cast({:register_node, node_id, server}, state) do
    case KBuckets.item(state.network, node_id) do
      nil -> {:noreply, register_node(state, node_id, server)}
      %KBuckets.Item{} -> {:noreply, state}
    end
  end

  # Private call used by PeerHandler when is stable for 10 msgs and 30 seconds
  def handle_cast({:stable_node, node_id, server}, state) do
    case KBuckets.item(state.network, node_id) do
      nil ->
        {:noreply, register_node(state, node_id, server)}

      %KBuckets.Item{} = node ->
        network = KBuckets.update_item(state.network, %KBuckets.Item{node | retries: 0})
        if node.retries > 0, do: redistribute(network, node)
        {:noreply, %{state | network: network}}
    end
  end

  # Private call used by PeerHandler when connections fail
  def handle_cast({:failed_node, node}, state) do
    case KBuckets.item(state.network, node) do
      nil -> {:noreply, state}
      item -> {:noreply, %{state | network: do_failed_node(item, state.network)}}
    end
  end

  def handle_cast({:broadcast, msg}, state = %Kademlia{network: network}) do
    msg = [PeerHandler.publish(), msg]

    list =
      KBuckets.to_list(network)
      |> filter_online()

    max = length(list) |> :math.sqrt() |> trunc
    num = if max > @broadcast_factor, do: max, else: @broadcast_factor

    list
    |> Enum.take_random(num)
    |> Enum.each(fn item -> rpcast(item, msg) end)

    {:noreply, state}
  end

  defp register_node(state = %Kademlia{network: network}, node_id, server) do
    KademliaSql.maybe_update_object(nil, server)

    node = %KBuckets.Item{
      node_id: node_id,
      last_connected: System.os_time(:second)
    }

    network = KBuckets.insert_item(network, node)

    # Because of bucket size limit, the new node might not get stored
    if KBuckets.member?(network, node_id) do
      redistribute(network, node)
    end

    %{state | network: network}
  end

  defp next_retry(%KBuckets.Item{retries: failures, last_error: last}) do
    if failures == 0 or last == nil do
      -1
    else
      factor = min(failures, 7)
      last + round(:math.pow(5, factor))
    end
  end

  def rpc(nodes, call) when is_list(nodes) do
    me = self()
    ref = make_ref()

    Enum.map(nodes, fn node ->
      spawn_link(fn ->
        send(me, {ref, rpc(node, call)})
      end)
    end)
    |> Enum.map(fn _pid ->
      receive do
        {^ref, ret} ->
          ret
      end
    end)
  end

  def rpc(%KBuckets.Item{node_id: node_id} = node, call) do
    pid = ensure_node_connection(node)

    try do
      GenServer.call(pid, {:rpc, call}, 2000)
    rescue
      error ->
        IO.puts("Failed to get a result from #{Wallet.printable(node_id)} #{inspect(error)}")
        []
    catch
      :exit, {:timeout, _} ->
        IO.puts("Timeout while getting a result from #{Wallet.printable(node_id)}")
        # TODO: This *always* happens when a node is still syncing. How to handle this better?
        # Process.exit(pid, :timeout)
        []

      any, what ->
        IO.puts(
          "Failed(2) to get a result from #{Wallet.printable(node_id)} #{inspect({any, what})}"
        )

        []
    end
  end

  def rpcast(%KBuckets.Item{} = node, call) do
    GenServer.cast(ensure_node_connection(node), {:rpc, call})
  end

  @doc """
    redistribute resends all key/values that are nearer to the given node to
    that node
  """
  @max_key 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  def redistribute(network, node) do
    online = Network.Server.get_connections(PeerHandler)
    node = %KBuckets.Item{} = KBuckets.item(network, node)

    # IO.puts("redistribute(#{inspect(node)})")
    previ =
      case filter_online(KBuckets.prev(network, node), online) do
        [prev | _] -> KBuckets.integer(prev)
        [] -> KBuckets.integer(node)
      end

    nodei = KBuckets.integer(node)

    nexti =
      case filter_online(KBuckets.next(network, node), online) do
        [next | _] -> KBuckets.integer(next)
        [] -> KBuckets.integer(node)
      end

    range_start = rem(div(previ + nodei, 2), @max_key)
    range_end = rem(div(nexti + nodei, 2), @max_key)

    objs = KademliaSql.objects(range_start, range_end)
    # IO.puts("redistribute() -> #{length(objs)}")
    Enum.each(objs, fn {key, value} -> rpcast(node, [PeerHandler.store(), key, value]) end)
  end

  # -------------------------------------------------------------------------------------
  # Helpers calls
  # -------------------------------------------------------------------------------------
  @impl true
  def init(:ok) do
    EtsLru.new(__MODULE__, 2048, fn value ->
      case value do
        nil -> false
        [] -> false
        _ -> true
      end
    end)

    kb =
      Chain.load_file(Diode.data_dir(@storage_file), fn ->
        %Kademlia{network: KBuckets.new()}
      end)

    for node <- KBuckets.to_list(kb.network) do
      if Map.has_key?(node, :object) and is_tuple(node.object) do
        KademliaSql.maybe_update_object(nil, node.object)
      end
    end

    {:ok, kb, {:continue, :seed}}
  end

  @doc "Method used for testing"
  def reset() do
    call(fn _from, _state ->
      {:reply, :ok, %Kademlia{network: KBuckets.new()}}
    end)
  end

  def append(key, value, store_self \\ false) do
    GenServer.call(__MODULE__, {:append, key, value, store_self})
  end

  # -------------------------------------------------------------------------------------
  # Private calls
  # -------------------------------------------------------------------------------------

  defp ensure_node_connection(item = %KBuckets.Item{node_id: node_id}) do
    if KBuckets.is_self(item) do
      Network.Server.ensure_node_connection(
        PeerHandler,
        node_id,
        "localhost",
        Diode.peer_port()
      )
    else
      server = KBuckets.object(item)
      host = Server.host(server)
      port = Server.peer_port(server)
      Network.Server.ensure_node_connection(PeerHandler, node_id, host, port)
    end
  end

  defp do_failed_node(item = %KBuckets.Item{retries: retries}, network) do
    if KBuckets.is_self(item) do
      network
    else
      KBuckets.update_item(network, %KBuckets.Item{
        item
        | retries: retries + 1,
          last_error: System.os_time(:second)
      })
    end
  end

  def do_find_nodes(key, k, cmd) do
    # :io.format("KademliaSearch.find_nodes(key=#{Base16.encode(key)}, nearest=~p, k=#{k}, cmd=#{cmd})~n", [Enum.map(nearest, &port/1)])
    get_cached(
      fn {cmd, key} ->
        KademliaSearch.find_nodes(key, find_node_lookup(key), k, cmd)
      end,
      {cmd, key}
    )
  end

  def nearest_n(key, network \\ network()) do
    KBuckets.nearest(network, key)
    |> filter_online()
    |> Enum.take(KBuckets.k())
  end

  defp filter_online(list, online \\ Network.Server.get_connections(PeerHandler)) do
    Enum.filter(list, fn %KBuckets.Item{node_id: wallet} = item ->
      KBuckets.is_self(item) or Map.has_key?(online, Wallet.address!(wallet))
    end)
  end

  @cache_timeout 20_000
  defp get_cached(fun, key) do
    cache_key = {fun, key}

    case EtsLru.get(__MODULE__, cache_key) do
      nil ->
        EtsLru.fetch(__MODULE__, cache_key, fn -> fun.(key) end)

      other ->
        Debouncer.immediate(
          cache_key,
          fn -> EtsLru.put(__MODULE__, cache_key, fun.(key)) end,
          @cache_timeout
        )

        other
    end
  end

  defp call(fun) do
    GenServer.call(__MODULE__, {:call, fun})
  end

  def hash(binary) do
    Diode.hash(binary)
  end
end
