# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule EtsLru do
  @moduledoc """
  Provides Least-Recently-Used Queue with a fixed maximum size
  """

  def new(name \\ nil, max_size) do
    name =
      case name do
        nil -> :ets.new(name, [:public])
        _other -> :ets.new(name, [:named_table, :public])
      end

    :ets.insert(name, {:meta, 0, max_size})
    name
  end

  def destroy(name) do
    :ets.delete(name)
  end

  def put(lru, key, value) do
    n = :ets.update_counter(lru, :meta, 1)

    key = {:key, key}
    :ets.insert(lru, {key, value, n})
    :ets.insert(lru, {n, key})

    max_size = :ets.lookup_element(lru, :meta, 3)
    del = n - max_size

    if del > 0 do
      [{^del, key}] = :ets.lookup(lru, del)
      :ets.delete(lru, del)

      case :ets.lookup(lru, key) do
        [{^key, _value, ^del}] -> :ets.delete(lru, key)
        _ -> :ok
      end
    end

    value
  end

  def get(lru, key, default \\ nil) do
    case :ets.lookup(lru, {:key, key}) do
      [{_key, value, _n}] -> value
      [] -> default
    end
  end

  def fetch(lru, key, fun) do
    case :ets.lookup(lru, {:key, key}) do
      [{_key, value, _n}] ->
        value

      [] ->
        case fun.() do
          nil -> nil
          value -> put(lru, key, value)
        end
    end
  end

  def size(lru) do
    total_size = :ets.info(lru, :size)
    div(total_size - 1, 2)
  end

  def to_list(lru) do
    for {{:key, key}, value, _n} <- :ets.tab2list(lru), do: {key, value}
  end
end
