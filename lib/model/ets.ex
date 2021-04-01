# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.Ets do
  def init(name, extra \\ []) do
    ^name = :ets.new(name, [:named_table, :public] ++ extra)
  end

  def clear(name) do
    :ets.delete_all_objects(name)
  end

  def put(name, idx, item) do
    :ets.insert(name, {idx, item})
  end

  def remove(name, idx) do
    :ets.delete(name, idx)
  end

  def all(name) do
    :ets.tab2list(name)
    |> Enum.map(fn {_key, value} -> value end)
  end

  def lookup(name, idx, default \\ fn -> nil end) do
    case :ets.lookup(name, idx) do
      [] -> default.()
      [{^idx, item}] -> item
    end
  end
end
