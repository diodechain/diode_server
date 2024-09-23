# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule EtsLru do
  @moduledoc """
  Provides Least-Recently-Used Queue with a fixed maximum size
  """

  def new(name, max_size, filter \\ fn _ -> true end) do
    name =
      case name do
        nil -> :ets.new(name, [:public])
        _other -> :ets.new(name, [:named_table, :public])
      end

    :ets.insert(name, {:meta, 0, max_size, filter})
    name
  end

  def destroy(name) do
    :ets.delete(name)
  end

  def put(lru, key, value) do
    filter_fun = filter(lru)

    if filter_fun.(value) and get(lru, key) != value do
      key = {:key, key}
      n = :ets.update_counter(lru, :meta, 1)

      :ets.insert(lru, {key, value, n})
      :ets.insert(lru, {n, key})

      max_size = :ets.lookup_element(lru, :meta, 3)
      del = n - max_size

      if del > 0 do
        with [{^del, key}] <- :ets.lookup(lru, del) do
          :ets.delete(lru, del)

          with [{^key, _value, ^del}] <- :ets.lookup(lru, key) do
            :ets.delete(lru, key)
          end
        end
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

  def delete(lru, key) do
    :ets.delete(lru, {:key, key})
  end

  def fetch(lru, key, fun) do
    if is_atom(lru) and :ets.whereis(lru) == :undefined do
      fun.()
    else
      case :ets.lookup(lru, {:key, key}) do
        [{_key, value, _n}] ->
          value

        [] ->
          :global.trans({key, self()}, fn ->
            fetch_nolock(lru, key, fun)
          end)
      end
    end
  end

  def update(lru, key, fun) do
    :global.trans({key, self()}, fn ->
      put(lru, key, eval(fun))
    end)
  end

  def fetch_nolock(lru, key, fun) do
    case :ets.lookup(lru, {:key, key}) do
      [{_key, value, _n}] -> value
      [] -> put(lru, key, eval(fun))
    end
  end

  def size(lru) do
    total_size = :ets.info(lru, :size)
    div(total_size - 1, 2)
  end

  def to_list(lru) do
    for {{:key, key}, value, _n} <- :ets.tab2list(lru), do: {key, value}
  end

  def filter(lru) do
    :ets.lookup_element(lru, :meta, 4)
  end

  def max_size(lru) do
    :ets.lookup_element(lru, :meta, 3)
  end

  def set_max_size(lru, max_size) do
    :ets.update_element(lru, :meta, [{3, max_size}])
  end

  def flush(lru) do
    filter = filter(lru)
    max_size = max_size(lru)
    :ets.delete_all_objects(lru)
    :ets.insert(lru, {:meta, 0, max_size, filter})
  end

  #
  # Private functions below
  #

  defp eval(fun) when is_function(fun, 0) do
    fun.()
  end

  defp eval({m, f, a}) do
    apply(m, f, a)
  end
end
