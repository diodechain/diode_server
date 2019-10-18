defmodule KademliaSearch do
  @moduledoc """
    A @alpha multi-threaded kademlia search. Starts a master as well as @alpha workers
    and executed the specified cmd query in the network.
  """
  use GenServer
  @max_oid 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1
  @alpha 3

  def init(:ok) do
    :erlang.process_flag(:trap_exit, true)
    {:ok, %{}}
  end

  def find_nodes(key, nearest, k, cmd) do
    {:ok, pid} = GenServer.start_link(__MODULE__, :ok)
    GenServer.call(pid, {:find_nodes, key, nearest, k, cmd})
  end

  def handle_call({:find_nodes, key, nearest, k, cmd}, from, %{}) do
    state = %{
      tasks: [],
      from: from,
      key: key,
      min_distance: @max_oid,
      queryable: nearest,
      k: k,
      visited: [],
      waiting: [],
      queried: [],
      cmd: cmd
    }

    tasks = for _ <- 1..@alpha, do: start_worker(state)
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:EXIT, worker_pid, _reason}, state) do
    tasks = Enum.reject(state.tasks, fn pid -> pid == worker_pid end)
    tasks = [start_worker(state) | tasks]
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:kadret, {:value, value}, _distance, _task}, state) do
    ret = KBuckets.unique(state.visited ++ state.queried)
    GenServer.reply(state.from, {:value, value, ret})
    {:stop, :normal, nil}
  end

  def handle_info({:kadret, nodes, distance, task}, state) do
    waiting = [task | state.waiting]
    visited = KBuckets.unique(state.visited ++ nodes)

    min_distance = min(distance, state.min_distance)

    # only those that are nearer
    queryable =
      KBuckets.unique(state.queryable ++ nodes)
      |> Enum.filter(fn node ->
        KBuckets.distance(state.key, node) < min_distance and
          KBuckets.member?(state.queried, node) == false
      end)
      |> KBuckets.nearest_n(state.key, state.k)

    sends = min(length(queryable), length(waiting))
    {nexts, queryable} = Enum.split(queryable, sends)
    {pids, waiting} = Enum.split(waiting, sends)
    Enum.zip(nexts, pids) |> Enum.map(fn {next, pid} -> send(pid, {:next, next}) end)
    queried = state.queried ++ nexts

    if queryable == [] and length(waiting) == @alpha do
      ret = KBuckets.unique(visited ++ queried)
      GenServer.reply(state.from, ret)
      {:stop, :normal, nil}
    else
      {:noreply,
       %{
         state
         | min_distance: min_distance,
           queryable: queryable,
           visited: visited,
           waiting: waiting,
           queried: queried
       }}
    end
  end

  defp start_worker(state) do
    {:ok, pid} = Task.start_link(__MODULE__, :worker_loop, [nil, state.key, self(), state.cmd])
    pid
  end

  def worker_loop(node, key, father, cmd) do
    # :io.format("worker_loop(#{inspect(node)}, ~n~400p, ~400p)~n", [key, father])

    case node do
      nil ->
        send(father, {:kadret, [], @max_oid, self()})

      node ->
        ret = Kademlia.rpc(node, [cmd, key])
        send(father, {:kadret, ret, KBuckets.distance(node, key), self()})
    end

    receive do
      {:next, node} -> worker_loop(node, key, father, cmd)
      :done -> :ok
    end
  end
end
