defmodule LocalStore do
  @spec init() :: :ok
  def init() do
    Store.create_table!(:objects, [
      {:disc_copies, [node()]},
      {:attributes, [:object_id, :network_id, :size, :object]},
      {:storage_properties, [{:ets, [:compressed]}, {:dets, [{:auto_save, 5000}]}]}
    ])
  end

  def clear() do
    :mnesia.delete_table(:objects)
    init()
  end

  def append!(network_id, key, value) do
    # Mnesia list storage for prototype
    {:atomic, _} =
      :mnesia.transaction(fn ->
        # This code is optimistically converting non lists and empty entries into
        # lists on write.
        case :mnesia.read(:objects, key) do
          # [:object_id, :network_id, :size, :object]
          [] ->
            internal_write(network_id, key, [value])

          [{:objects, key, network_id, _size, list}] when is_list(list) ->
            internal_write(network_id, key, [value | list])

          [{:objects, key, network_id, _size, nonlist}] ->
            internal_write(network_id, key, [value, nonlist])
        end
      end)
  end

  def store(network_id \\ nil, key, value) do
    # :io.format("LocalStore.store(~p, ~p)~n", [key, value])

    {:atomic, _} =
      :mnesia.transaction(fn ->
        internal_write(network_id, key, value)
      end)
  end

  def find(key) do
    {:atomic, value} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:objects, key) do
          [] -> nil
          [{:objects, ^key, _, _, value}] -> value
        end
      end)

    value
  end

  defp internal_write(network_id, key, object) do
    # [:object_id, :network_id, :size, :object]
    :mnesia.write({:objects, key, network_id, :erlang.iolist_size(object), object})
  end
end
