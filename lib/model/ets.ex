# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
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

  def lookup(name, idx, default \\ fn -> nil end) do
    case :ets.lookup(name, idx) do
      [] -> default.()
      [{^idx, item}] -> item
    end
  end
end
