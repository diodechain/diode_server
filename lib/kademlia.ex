# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Kademlia do
  @moduledoc """
    Kademlia.ex is in fact a K* implementation. K* star is a modified version of Kademlia
    using the same KBuckets scheme to keep track of which nodes to remember. But instead of
    using the XOR metric it is using geometric distance on a ring as node value distance.
    Node distance is symmetric on the ring.
  """
  use GenServer
  alias Network.PeerHandler, as: Client
  alias Object.Server, as: Server
  alias Model.KademliaSql
  @k 3
  @relay_factor 3
  @broadcast_factor 50

  defstruct tasks: %{}, network: nil, cache: Lru.new(1024)
  @type t :: %Kademlia{tasks: Map.t(), network: KBuckets.t(), cache: Lru.t()}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  @spec ping(any) :: any
  def ping(node_id) do
    rpc(find_node(node_id), [Client.ping()])
  end

  @doc """
    broadcast is used to broadcast self generated blocks/transactions through the network
  """
  def broadcast(msg) do
    msg = [Client.publish(), msg]
    list = KBuckets.to_list(network())

    max = length(list) |> :math.sqrt() |> trunc
    num = if max > @broadcast_factor, do: max, else: @broadcast_factor

    list
    |> Enum.reject(fn a -> KBuckets.is_self(a) end)
    |> Enum.take_random(num)
    |> Enum.each(fn item -> rpcast(item, msg) end)
  end

  @doc """
    relay is used to forward NEW received blocks/transactions further through the network
  """
  def relay(msg) do
    msg = [Client.publish(), msg]

    KBuckets.next_n(network(), @relay_factor)
    |> Enum.each(fn item -> rpcast(item, msg) end)
  end

  @doc """
    store() stores the given key-value pair in the @k nodes
    that are closest to the key
  """
  @spec store(binary(), any()) :: any()
  def store(key, value) do
    nodes = find_nodes(key)
    key = hash(key)
    nearest = KBuckets.nearest_n(nodes, key, @k)

    # :io.format("Storing #{value} at ~p as #{Base16.encode(key)}~n", [Enum.map(nearest, &port/1)])
    rpc(nearest, [Client.store(), key, value])
  end

  @doc """
    find_value() is different from store() in that it might return
    an earlier result
  """
  @spec find_value(binary()) :: any()
  def find_value(key) do
    key = hash(key)

    case do_node_lookup(key) do
      {_, nearest} ->
        nodes = do_find_nodes(key, nearest, KBuckets.k(), Client.find_value())

        case nodes do
          {:value, value, visited} ->
            result = KBuckets.nearest_n(visited, key, KBuckets.k())

            call(fn _from, state ->
              network = KBuckets.insert_items(state.network, visited)
              cache = Lru.insert(state.cache, key, result)
              {:reply, :ok, %Kademlia{state | network: network, cache: cache}}
            end)

            # Kademlia logic: Writing found result to second nearest node
            case Enum.at(result, 1) do
              nil -> :nothing
              second_nearest -> rpcast(second_nearest, [Client.store(), key, value])
            end

            value

          visited ->
            call(fn _from, state ->
              network = KBuckets.insert_items(state.network, visited)
              {:reply, :ok, %Kademlia{state | network: network}}
            end)

            nil
        end
    end
  end

  @spec find_node(Wallet.address()) :: nil | KBuckets.Item.t()
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

  @spec find_nodes(any()) :: [KBuckets.Item.t()]
  def find_nodes(key) do
    key = hash(key)

    case do_node_lookup(key) do
      {:cached, result} ->
        result

      {:network, nearest} ->
        visited = do_find_nodes(key, nearest, KBuckets.k(), Client.find_node())
        result = KBuckets.nearest_n(visited, key, KBuckets.k())

        call(fn _from, state ->
          network = KBuckets.insert_items(state.network, visited)
          cache = Lru.insert(state.cache, key, result)
          {:reply, :ok, %Kademlia{state | network: network, cache: cache}}
        end)

        result
    end
  end

  @spec find_node_lookup(any()) :: [KBuckets.item()]
  def find_node_lookup(key) do
    {_, nodes} = do_node_lookup(key)
    nodes
  end

  def network() do
    call(fn _from, state -> {:reply, state.network, state} end)
  end

  def handle_call({:call, fun}, from, state) do
    fun.(from, state)
  end

  def handle_call({:append, key, value, _store_self}, _from, queue) do
    KademliaSql.append!(key, value)
    {:reply, :ok, queue}
  end

  def handle_call(:get_network, _from, state) do
    {:reply, state.network, state}
  end

  def handle_call({:register_node, node_id, server}, _from, state) do
    {:reply, :ok, register_node(state, node_id, server)}
  end

  def handle_info(:save, state) do
    spawn(fn -> Chain.store_file(Diode.data_dir("kademlia.etf"), state) end)
    Process.send_after(self(), :save, 60_000)
    {:noreply, state}
  end

  def handle_info(:contact_seeds, state) do
    for seed <- Diode.seeds() do
      %URI{userinfo: node_id, host: address, port: port} = URI.parse(seed)

      id =
        case node_id do
          nil -> Wallet.new()
          str -> Wallet.from_address(Base16.decode(str))
        end

      Network.Server.ensure_node_connection(Network.PeerHandler, id, address, port)
    end

    Process.send_after(self(), :contact_seeds, 60_000)
    {:noreply, state}
  end

  def handle_continue(:seed, state) do
    Process.send_after(self(), :save, 60_000)
    handle_info(:contact_seeds, state)
    {:noreply, state}
  end

  # Private call used by PeerHandler when connections are established
  def handle_cast({:register_node, node_id, server}, state) do
    {:noreply, register_node(state, node_id, server)}
  end

  # Private call used by PeerHandler when is stable for 10 msgs and 30 seconds
  def handle_cast({:stable_node, node_id, server}, state) do
    case KBuckets.item(state.network, node_id) do
      nil ->
        {:noreply, register_node(state, node_id, server)}

      node ->
        network = KBuckets.update_item(state.network, %{node | retries: 0})
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

  defp register_node(state, node_id, server) do
    if KBuckets.member?(state.network, node_id) do
      state
    else
      node = %KBuckets.Item{
        node_id: node_id,
        object: server,
        last_seen: System.os_time(:second)
      }

      network = KBuckets.insert_item(state.network, node)

      # Because of bucket size limit, the new node might not get stored
      if KBuckets.member?(network, node_id) do
        redistribute(network, node)
      end

      %{state | network: network}
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
      _error ->
        IO.puts("Failed to get a result from #{Wallet.printable(node_id)}")
        []
    catch
      _any, _what ->
        IO.puts("Failed(2) to get a result from #{Wallet.printable(node_id)}")
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
    node = %KBuckets.Item{} = KBuckets.item(network, node)

    # IO.puts("redistribute(#{inspect(node)})")
    previ = KBuckets.prev_n(network, node, 1) |> hd() |> KBuckets.integer()
    nodei = KBuckets.integer(node)
    nexti = KBuckets.next_n(network, node, 1) |> hd() |> KBuckets.integer()

    range_start = rem(div(previ + nodei, 2), @max_key)
    range_end = rem(div(nexti + nodei, 2), @max_key)

    objs = KademliaSql.objects(range_start, range_end)
    # IO.puts("redistribute() -> #{length(objs)}")
    Enum.each(objs, fn {key, value} -> rpcast(node, [Client.store(), key, value]) end)
  end

  # -------------------------------------------------------------------------------------
  # Helpers calls
  # -------------------------------------------------------------------------------------
  def port(nil) do
    nil
  end

  def port(node) do
    if is_atom(node.object), do: node.object, else: Object.Server.edge_port(node.object)
  end

  def init(:ok) do
    kb =
      Chain.load_file(Diode.data_dir("kademlia.etf"), fn ->
        %Kademlia{network: KBuckets.new(Diode.miner())}
      end)

    {:ok, kb, {:continue, :seed}}
  end

  @doc "Method used for testing"
  def reset() do
    call(fn _from, _state ->
      {:reply, :ok, %Kademlia{network: KBuckets.new(Diode.miner())}}
    end)
  end

  def append(key, value, store_self \\ false) do
    GenServer.call(__MODULE__, {:append, key, value, store_self})
  end

  # -------------------------------------------------------------------------------------
  # Private calls
  # -------------------------------------------------------------------------------------

  defp ensure_node_connection(%KBuckets.Item{node_id: node_id, object: :self}) do
    Network.Server.ensure_node_connection(
      Network.PeerHandler,
      node_id,
      "localhost",
      Diode.peer_port()
    )
  end

  defp ensure_node_connection(%KBuckets.Item{node_id: node_id, object: server}) do
    host = Server.host(server)
    port = Server.peer_port(server)
    Network.Server.ensure_node_connection(Network.PeerHandler, node_id, host, port)
  end

  defp do_failed_node(%{object: :self}, network) do
    network
  end

  defp do_failed_node(item, network) do
    now = System.os_time(:second)

    case item.retries do
      0 ->
        KBuckets.update_item(network, %{item | retries: 1, last_seen: now + 5})

      failures when failures > 10 ->
        # With
        # 5 + 5×5 + 5×5×5 + 5×5×5×5 + 5×5×5×5×5 +
        # 5x (5×5×5×5×5×5)
        # This will delete an item after 24h of failures
        IO.puts("Deleting node #{Wallet.printable(item.node_id)} after 10 retries")
        KBuckets.delete_item(network, item)

      failures ->
        factor = min(failures, 5)
        next = now + round(:math.pow(5, factor))
        KBuckets.update_item(network, %{item | retries: failures + 1, last_seen: next})
    end
  end

  defp do_find_nodes(key, nearest, k, cmd) do
    # :io.format("KademliaSearch.find_nodes(key=#{Base16.encode(key)}, nearest=~p, k=#{k}, cmd=#{cmd})~n", [Enum.map(nearest, &port/1)])
    KademliaSearch.find_nodes(key, nearest, k, cmd)
  end

  # Retrieves for the target key either the last cached values or
  # the nearest k entries from the KBuckets store
  @spec do_node_lookup(any()) :: {:network | :cached, [KBuckets.item()]}
  defp do_node_lookup(key) do
    call(fn _from, state ->
      # case Lru.get(state.cache, key) do
      # nil ->
      nodes = {:network, KBuckets.nearest_n(state.network, key, KBuckets.k())}
      # cached -> {:cached, cached}
      # end

      # :io.format("do_node_lookup(key) -> ~p, ~p~n", [elem(nodes, 0), length(elem(nodes, 1))])
      {:reply, nodes, state}
    end)
  end

  defp call(fun) do
    GenServer.call(__MODULE__, {:call, fun})
  end

  defp hash(binary) do
    Diode.hash(binary)
  end
end
