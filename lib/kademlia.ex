defmodule Kademlia do
  use GenServer
  alias Network.PeerHandler, as: Client
  alias Object.Server, as: Server

  # 2^256
  @max_oid 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1

  defstruct tasks: %{}, network: nil, cache: Lru.new(1024)
  @type t :: %Kademlia{tasks: Map.t(), network: KBuckets.t(), cache: Lru.t()}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def ping(node_id) do
    GenServer.call(__MODULE__, {:ping, node_id})
  end

  def publish(object) do
    GenServer.cast(__MODULE__, {:publish, object})
  end

  # def store_device(device_id) do
  #  store("client/" <> device_id, Store.identity())
  #  # proof ?
  # end

  @doc """
    store() stores the given key-value pair in the single node that
    is closest to the key
  """
  @spec store(binary(), any()) :: any()
  def store(key, value) do
    key = KBuckets.hash(key)
    nodes = find_nodes(key)
    [nearest] = KBuckets.nearest_n(nodes, key, 1)
    rpc(nearest, [Client.store(), key, value])
  end

  @doc """
    find_value() is different from store() in that it might return
    an earlier result
  """
  @spec find_value(binary()) :: any()
  def find_value(key) do
    key = KBuckets.hash(key)

    case do_node_lookup(key) do
      {_, nearest} ->
        case do_find_nodes(key, nearest, KBuckets.k(), Client.find_value()) do
          {:value, value, visited} ->
            result = KBuckets.nearest_n(visited, key, KBuckets.k())

            call(fn _from, state ->
              network = KBuckets.insert_items(state.network, visited)
              cache = Lru.insert(state.cache, key, result)
              {:reply, :ok, %Kademlia{state | network: network, cache: cache}}
            end)

            case Enum.at(result, 1) do
              nil -> :nothing
              second_nearest -> rpc(second_nearest, [Client.store(), key, value])
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

  def init(:ok) do
    kb =
      Chain.load_file(Diode.dataDir("kademlia.etf"), fn ->
        %Kademlia{network: KBuckets.new(Store.wallet())}
      end)

    {:ok, kb, {:continue, :seed}}
  end

  @doc "Method used for testing"
  def reset() do
    call(fn _from, _state -> {:reply, :ok, %Kademlia{network: KBuckets.new(Store.wallet())}} end)
  end

  def append(key, value, store_self \\ false) do
    GenServer.call(__MODULE__, {:append, key, value, store_self})
  end

  @spec find_node(any()) :: nil | KBuckets.Item.t()
  def find_node(key) do
    case find_nodes(key) do
      [] ->
        nil

      [first | _] ->
        case Wallet.address!(first.node_id) do
          ^key -> first
          _ -> nil
        end
    end
  end

  @spec find_nodes(any()) :: [KBuckets.Item.t()]
  def find_nodes(key) do
    key = KBuckets.hash(key)

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

  defp do_find_nodes(key, nearest, k, cmd) do
    KademliaSearch.find_nodes(key, nearest, k, cmd)
  end

  @spec find_node_lookup(any()) :: [KBuckets.item()]
  def find_node_lookup(key) do
    {_, nodes} = do_node_lookup(key)
    nodes
  end

  # Retrieves for the target key either the last cached values or
  # the nearest k entries from the KBuckets store
  @spec do_node_lookup(any()) :: {:network | :cached, [KBuckets.item()]}
  defp do_node_lookup(key) do
    call(fn _from, state ->
      nodes =
        case Lru.get(state.cache, key) do
          nil -> {:network, KBuckets.nearest_n(state.network, key, KBuckets.k())}
          cached -> {:cached, cached}
        end

      {:reply, nodes, state}
    end)
  end

  defp call(fun) do
    GenServer.call(__MODULE__, {:call, fun})
  end

  def network() do
    call(fn _from, state -> {:reply, state.network, state} end)
  end

  def handle_call({:call, fun}, from, state) do
    fun.(from, state)
  end

  def handle_call({:append, key, value, _store_self}, _from, queue) do
    KademliaStore.append!(key, value)
    {:reply, :ok, queue}
  end

  def handle_call(:get_network, _from, state) do
    {:reply, state.network, state}
  end

  def handle_info(:save, state) do
    spawn(fn -> Chain.store_file(Diode.dataDir("kademlia.etf"), state) end)
    Process.send_after(self(), :save, 60_000)
    {:noreply, state}
  end

  # Private call used by PeerHandler when connections are established
  def handle_cast({:register_node, node_id, server}, state) do
    kb =
      KBuckets.insert_item(
        state.network,
        %KBuckets.Item{
          node_id: node_id,
          object: server,
          last_seen: :os.system_time()
        }
      )

    {:noreply, %Kademlia{network: kb}}
  end

  def handle_cast({:publish, object}, state) do
    broadcast(state, 3, [Client.publish(), object])
    {:noreply, state}
  end

  # Private call used by PeerHandler when connections fail
  def handle_cast({:failed_node, node}, state) do
    :io.format("Connection failed to ~p~n", [Wallet.printable(node)])

    case KBuckets.item(state.network, node) do
      nil ->
        {:noreply, state}

      item ->
        {:noreply, %{state | network: do_failed_node(item, state.network)}}
    end
  end

  defp do_failed_node(item, network) do
    now = :os.system_time()

    case item.retries do
      0 ->
        KBuckets.update_item(network, %{item | retries: 1, last_seen: now + 5})

      failures when failures > 10 ->
        # With
        # 5 + 5×5 + 5×5×5 + 5×5×5×5 + 5×5×5×5×5 +
        # 5x (5×5×5×5×5×5)
        # This will delete an item after 24h of failures
        KBuckets.delete_item(network, item)

      failures ->
        if item.last_seen < now do
          factor = min(failures, 5)
          next = now + round(:math.pow(5, factor))
          KBuckets.update_item(network, %{item | retries: failures + 1, last_seen: next})
        else
          network
        end
    end
  end

  defp broadcast(state, n, msg) do
    ensure_connections(state, n)
    |> Enum.each(fn pid ->
      GenServer.cast(pid, {:rpc, msg})
    end)
  end

  defp ensure_connections(state, n) do
    candidates =
      Network.Server.get_connections(Network.PeerHandler)
      |> Map.values()

    if length(candidates) < n do
      list =
        KBuckets.to_list(state.network)
        |> Enum.filter(&(not KBuckets.is_self(&1)))
        |> Enum.filter(&(not Enum.member?(candidates, &1)))
        |> Enum.take_random(n - length(candidates))
        |> Enum.map(&ensure_node_connection/1)

      candidates ++ list
    else
      Enum.take_random(candidates, n)
    end
  end

  def handle_continue(:seed, state) do
    Process.send_after(self(), :save, 60_000)

    ensure_connections(state, 3)

    for seed <- Diode.seeds() do
      %URI{userinfo: node_id, host: address, port: port} = URI.parse(seed)

      id =
        case node_id do
          nil -> nil
          str -> Wallet.from_address(Base16.decode(str))
        end

      Network.Server.ensure_node_connection(Network.PeerHandler, id, address, port)
    end

    {:noreply, state}
  end

  @spec oid_multiply(<<_::256>>, integer()) :: [any()]
  def oid_multiply(oid, factor) do
    # factor needs to be factor of 2 (2, 4, 8, 16, ...)
    <<oid_int::256>> = oid
    step = div(@max_oid, factor)

    2..factor
    |> Enum.reduce([oid_int], fn _, list ->
      [rem(List.first(list) + step, @max_oid) | list]
    end)
    |> Enum.map(fn integer ->
      <<integer::unsigned-size(256)>>
    end)
  end

  def rpc(%KBuckets.Item{object: :self}, call) do
    find_node_cmd = Client.find_node()
    find_value_cmd = Client.find_value()
    store_cmd = Client.store()

    case call do
      [^store_cmd, key, value] ->
        KademliaStore.store(key, value)

      [^find_node_cmd, _key] ->
        []

      [^find_value_cmd, key] ->
        case KademliaStore.find(key) do
          nil -> []
          value -> {:value, value}
        end
    end
  end

  def rpc(%KBuckets.Item{node_id: node_id} = node, call) do
    # :io.format("RPC: ~0p ~0p~n", [call, Wallet.printable(node_id)])
    # :io.format("BT ~0p", [:erlang.process_info(self(), :current_stacktrace)])
    pid = ensure_node_connection(node)

    try do
      GenServer.call(pid, {:rpc, call}, 500)
    rescue
      _error ->
        IO.puts("Failed to get a result from #{Wallet.printable(node_id)}")
        []
    end
  end

  defp ensure_node_connection(%KBuckets.Item{node_id: node_id, object: server}) do
    host = Server.host(server)
    port = Server.server_port(server)
    Network.Server.ensure_node_connection(Network.PeerHandler, node_id, host, port)
  end
end
