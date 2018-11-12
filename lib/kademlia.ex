defmodule Kademlia do
  use GenServer
  alias Network.PeerHandler, as: Client
  alias Object.Server, as: Server

  # 2^256
  @max_oid 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1
  @alpha 3

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
    {:ok, %Kademlia{network: KBuckets.new(Store.wallet())}, {:continue, :seed}}
  end

  def append(network_id, key, value, store_self \\ false) do
    GenServer.call(__MODULE__, {:append, network_id, key, value, store_self})
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
    tasks =
      Enum.map(1..@alpha, fn _ ->
        Task.async(__MODULE__, :query_worker, [nil, key, self(), cmd])
      end)

    queried = []
    ret = loop(key, @max_oid, nearest, k, [], [], queried)

    Enum.map(tasks, fn task ->
      send(task.pid, :done)
      Task.shutdown(task, 100)
    end)

    flush()

    case ret do
      {:value, value, visited} ->
        {:value, value, visited}

      visited ->
        visited
    end
  end

  defp flush() do
    receive do
      {:kadret, _any, _distance, _task} -> flush()
    after
      0 -> :ok
    end
  end

  defp loop(_key, _min_distance, [], _k, visited, waiting, queried)
       when length(waiting) == @alpha do
    KBuckets.unique(visited ++ queried)
  end

  defp loop(key, min_distance, queryable, k, visited, waiting, queried) do
    receive do
      {:kadret, {:value, value}, _distance, _task} ->
        {:value, value, KBuckets.unique(visited ++ queried)}

      {:kadret, nodes, distance, task} ->
        waiting = [task | waiting]
        visited = KBuckets.unique(visited ++ nodes)

        min_distance = min(distance, min_distance)

        # only those that are nearer
        queryable =
          KBuckets.unique(queryable ++ nodes)
          |> Enum.filter(fn node ->
            KBuckets.distance(key, node) < min_distance and
              KBuckets.member?(queried, node) == false
          end)
          |> KBuckets.nearest_n(key, k)

        sends = min(length(queryable), length(waiting))
        {nexts, queryable} = Enum.split(queryable, sends)
        {pids, waiting} = Enum.split(waiting, sends)
        Enum.zip(nexts, pids) |> Enum.map(fn {next, pid} -> send(pid, {:next, next}) end)
        queried = queried ++ nexts

        loop(key, min_distance, queryable, k, visited, waiting, queried)
    end
  end

  def query_worker(node, key, father, cmd) do
    # :io.format("query_worker(#{inspect(node)}, ~n~400p, ~400p)~n", [key, father])

    case node do
      nil ->
        send(father, {:kadret, [], @max_oid, self()})

      node ->
        ret = rpc(node, [cmd, key])
        send(father, {:kadret, ret, KBuckets.distance(node, key), self()})
    end

    receive do
      {:next, node} -> query_worker(node, key, father, cmd)
      :done -> :ok
    end
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

  def handle_call({:call, fun}, from, state) do
    fun.(from, state)
  end

  def handle_call({:append, network_id, key, value, _store_self}, _from, queue) do
    LocalStore.append!(network_id, key, value)
    {:reply, :ok, queue}
  end

  def handle_call(:get_network, _from, state) do
    {:reply, state.network, state}
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

  # Private call used by PeerHandler when connections fail
  def handle_cast({:failed_node, item}, state) do
    # Todo add retry counter
    kb = KBuckets.delete_item(state.network, item)
    {:noreply, %Kademlia{network: kb}}
  end

  def handle_cast({:publish, object}, state) do
    Network.Server.get_connections(Network.PeerHandler)
    |> Enum.take_random(3)
    |> Enum.each(fn {_, pid} ->
      GenServer.cast(pid, {:rpc, [Client.publish(), object]})
    end)

    {:noreply, state}
  end

  def handle_continue(:seed, state) do
    seed = Diode.seed()
    %URI{userinfo: node_id, host: address, port: port} = URI.parse(seed)

    id =
      case node_id do
        nil -> nil
        str -> Wallet.from_address(Base16.decode(str))
      end

    Network.Server.ensure_node_connection(Network.PeerHandler, id, address, port)
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

  defp rpc(%KBuckets.Item{object: :self}, call) do
    find_node_cmd = Client.find_node()
    find_value_cmd = Client.find_value()
    store_cmd = Client.store()

    case call do
      [^store_cmd, key, value] ->
        LocalStore.store(key, value)

      [^find_node_cmd, _key] ->
        []

      [^find_value_cmd, key] ->
        case LocalStore.find(key) do
          nil -> []
          value -> {:value, value}
        end
    end
  end

  defp rpc(%KBuckets.Item{node_id: node_id, object: server} = node, call) do
    host = Server.host(server)
    port = Server.server_port(server)
    pid = Network.Server.ensure_node_connection(Network.PeerHandler, node_id, host, port)
    tid = Task.async(GenServer, :call, [pid, {:rpc, call}])

    case Task.yield(tid, 5000) || Task.shutdown(tid) do
      {:ok, result} ->
        result

      nil ->
        IO.puts("Failed to get a result from #{Wallet.printable(node_id)}")
        GenServer.cast(Kademlia, {:failed_node, node})
        []
    end
  end
end
