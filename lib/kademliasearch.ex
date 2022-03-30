# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
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

  def handle_info({:EXIT, worker_pid, reason}, state) do
    :io.format("~p received :EXIT ~p~n", [__MODULE__, reason])
    tasks = Enum.reject(state.tasks, fn pid -> pid == worker_pid end)
    tasks = [start_worker(state) | tasks]
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:kadret, {:value, value}, _node, _task}, state) do
    # :io.format("Found ~p on node ~p~n", [value, node])
    ret = KBuckets.unique(state.visited ++ state.queried)
    GenServer.reply(state.from, {:value, value, ret})
    Enum.each(state.tasks, fn task -> send(task, :done) end)
    {:stop, :normal, nil}
  end

  def handle_info({:kadret, nodes, node, task}, state) do
    waiting = [task | state.waiting]
    visited = KBuckets.unique(state.visited ++ nodes)

    distance = if node == nil, do: @max_oid, else: KBuckets.distance(node, state.key)
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
    Enum.zip(nexts, pids) |> Enum.each(fn {next, pid} -> send(pid, {:next, next}) end)
    queried = state.queried ++ nexts

    if queryable == [] and length(waiting) == @alpha do
      ret = KBuckets.unique(visited ++ queried)
      GenServer.reply(state.from, ret)
      Enum.each(state.tasks, fn task -> send(task, :done) end)
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
    spawn_link(__MODULE__, :worker_loop, [nil, state.key, self(), state.cmd])
  end

  def worker_loop(node, key, father, cmd) do
    ret =
      if node == nil,
        do: [],
        else:
          Kademlia.rpc(node, [cmd, key])
          |> import_network_items()

    # :io.format("Kademlia.rpc(#{Kademlia.port(node)}, #{cmd}, #{Base16.encode(key)}) -> ~1200p~n", [ret])
    send(father, {:kadret, ret, node, self()})

    receive do
      {:next, node} -> worker_loop(node, key, father, cmd)
      :done -> :ok
    end
  end

  defp import_network_items(items) when is_list(items) do
    Enum.map(items, &import_network_item/1)
  end

  defp import_network_items(result) when is_tuple(result) do
    result
  end

  defp import_network_item(%{node_id: node_id, object: object}) do
    %KBuckets.Item{
      node_id: node_id,
      object: object
    }
  end
end
