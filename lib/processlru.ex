# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule ProcessLru do
  @moduledoc """
  Provides Least-Recently-Used Queue with a fixed maximum size
  """

  def new(name \\ nil, max_size) do
    name =
      case name do
        nil -> make_ref()
        _other -> name
      end

    Process.put({__MODULE__, name}, %{meta: {0, max_size}})
    name
  end

  def destroy(name) do
    Process.delete({__MODULE__, name})
  end

  def put(name, key, value) do
    do_put(map(name), name, key, value)
  end

  def do_put(%{meta: {n, max_size}} = lru, name, key, value) do
    lru = %{lru | meta: {n + 1, max_size}}
    n = n + 1

    key = {:key, key}

    lru = Map.put(lru, key, {value, n})
    lru = Map.put(lru, n, key)

    del = n - max_size

    if del > 0 do
      {key, lru} = Map.pop!(lru, del)

      lru =
        case Map.get(lru, key) do
          {_value, ^del} -> Map.delete(lru, key)
          _ -> lru
        end

      Process.put({__MODULE__, name}, lru)
    else
      Process.put({__MODULE__, name}, lru)
    end

    value
  end

  def do_put(_, _name, _key, value) do
    value
  end

  def get(name, key, default \\ nil) do
    case Map.get(map(name), {:key, key}) do
      {value, _n} -> value
      nil -> default
    end
  end

  def fetch(name, key, fun) do
    case Map.get(map(name), {:key, key}) do
      {value, _n} ->
        value

      nil ->
        case fun.() do
          nil -> nil
          value -> put(name, key, value)
        end
    end
  end

  def size(name) do
    total_size = map_size(map(name))
    div(total_size - 1, 2)
  end

  def to_list(name) do
    for {{:key, key}, value, _n} <- Map.to_list(map(name)), do: {key, value}
  end

  defp map(name) do
    Process.get({__MODULE__, name}, %{})
  end
end
