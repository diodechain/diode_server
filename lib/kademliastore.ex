# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule KademliaStore do
  @spec init() :: :ok
  def init() do
    Store.create_table!(:objects, [:object_id, :size, :object])
  end

  def clear() do
    :mnesia.delete_table(:objects)
    init()
  end

  def append!(key, value) do
    # Mnesia list storage for prototype
    {:atomic, _} =
      :mnesia.transaction(fn ->
        # This code is optimistically converting non lists and empty entries into
        # lists on write.
        case :mnesia.read(:objects, key) do
          # [:object_id, :size, :object]
          [] ->
            internal_write(key, [value])

          [{:objects, key, _size, list}] when is_list(list) ->
            internal_write(key, [value | list])

          [{:objects, key, _size, nonlist}] ->
            internal_write(key, [value, nonlist])
        end
      end)
  end

  def store(key, value) do
    # :io.format("KademliaStore.store(~p, ~p)~n", [key, value])

    {:atomic, _} =
      :mnesia.transaction(fn ->
        internal_write(key, value)
      end)
  end

  def find(key) do
    {:atomic, value} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:objects, key) do
          [] -> nil
          [{:objects, ^key, _size, value}] -> value
        end
      end)

    value
  end

  defp internal_write(key, object) do
    # [:object_id, :size, :object]
    :mnesia.write({:objects, key, :erlang.iolist_size(object), object})
  end
end
