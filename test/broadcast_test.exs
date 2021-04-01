# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule BroadcastTest do
  use ExUnit.Case, async: false

  setup_all do
    :ok
  end

  @tag timeout: :infinity
  test "geth reachability" do
    IO.puts("geth reachability")

    # for size <- [100, 200, 300, 400, 500] do
    for size <- [100, 200] do
      run(&geth_relayer/2, size)
      run(&geth_relayer/2, size)
      IO.puts("")
    end
  end

  test "diode reachability" do
    # for size <- [100] do
    IO.puts("diode reachability")

    # for size <- [100, 200, 300, 400, 500] do
    for size <- [100, 200] do
      run(&diode_relayer/2, size)
      run(&diode_relayer/2, size)
      IO.puts("")
    end
  end

  defp get(atom, pid) do
    send(pid, {atom, self()})

    receive do
      {:ok, value} -> value
    end
  end

  defp run(fun, size) do
    nodes = 1..size |> Enum.map(fn num -> {start_relayer(fun, num), num} end)
    :persistent_term.put(:broadcast_db, Map.new(nodes))

    Enum.each(nodes, fn {pid, _} -> send(pid, {:peers, nodes}) end)
    nodes = Keyword.keys(nodes)

    # Do stuff
    value = 1
    send(hd(nodes), {:broadcast, value})

    # Shutdown
    states = shutdown(nodes)

    {miss, count, rounds} =
      Enum.reduce(states, {[], 0, 0}, fn state, {miss, count, round} ->
        if Map.has_key?(state.received, value) do
          {miss, count + state.messages, max(round, state.received[value])}
        else
          {[state.id | miss], count + state.messages, round}
        end
      end)

    IO.puts(
      "Run #{size}: total #{count} messages in #{rounds} rounds. #{length(miss)} not reached"
    )

    # IO.puts(inspect(miss))
  end

  defp shutdown(nodes) do
    if Enum.all?(nodes, fn pid -> get(:busy, pid) end) do
      Process.sleep(100)
      shutdown(nodes)
    else
      Enum.map(nodes, fn pid -> get(:exit, pid) end)
    end
  end

  def start_relayer(fun, num) do
    spawn_link(fn ->
      relayer(
        %{
          sent: MapSet.new(),
          messages: -1,
          peers: [],
          received: %{},
          id: num,
          busy: true
        },
        fun
      )
    end)
  end

  def relayer(state, fun) do
    receive do
      {:exit, pid} ->
        send(pid, {:ok, state})
        exit(:normal)

      {:busy, pid} ->
        send(pid, {:ok, state.busy})
        state

      {:peers, peers} ->
        start = Enum.take_while(peers, fn {pid, _} -> pid != self() end)
        rest = Enum.slice(peers, (length(start) + 1)..length(peers))

        new_peers = rest ++ start
        %{state | peers: new_peers}

      other ->
        fun.(%{state | busy: true, messages: state.messages + 1}, other)
    after
      100 -> %{state | busy: false}
    end
    |> relayer(fun)
  end

  defp geth_relayer(state, event) do
    case event do
      {:broadcast, msg} ->
        size = trunc(:math.sqrt(length(state.peers)))

        sent =
          Enum.take_random(state.peers, size)
          |> send_peers({:msg, msg, 1})
          |> Enum.reduce(state.sent, fn peer, sent ->
            MapSet.put(sent, {peer, msg})
          end)

        received = Map.put(state.received, msg, 0)
        %{state | sent: sent, received: received}

      {:msg, msg, round} ->
        k = 50

        sent =
          Enum.reject(state.peers, fn peer -> MapSet.member?(state.sent, {peer, msg}) end)
          |> Enum.take_random(k)
          |> send_peers({:msg, msg, round + 1})
          |> Enum.reduce(state.sent, fn peer, sent ->
            MapSet.put(sent, {peer, msg})
          end)

        received = Map.put(state.received, msg, round)
        %{state | sent: sent, received: received}
    end
  end

  defp diode_relayer(state, event) do
    k = 3

    case event do
      {:broadcast, msg} ->
        size = trunc(:math.sqrt(length(state.peers)))

        Enum.take_every(state.peers, k)
        |> Enum.take_random(size)
        |> send_peers({:msg, msg, 1})

        received = Map.put(state.received, msg, 0)
        %{state | received: received}

      {:msg, msg, round} ->
        if state.received[msg] == nil do
          Enum.take(state.peers, k)
          |> send_peers({:msg, msg, round + 1})
        end

        received = Map.put(state.received, msg, round)
        %{state | received: received}
    end
  end

  defp send_peers(peers, what) do
    Enum.each(peers, fn {pid, _} -> send(pid, what) end)
    peers
  end
end
