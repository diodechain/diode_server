# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.KademliaSql do
  alias Model.Sql

  def query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  defp with_transaction(fun) do
    Sql.with_transaction(__MODULE__, fun)
  end

  def init() do
    with_transaction(fn db ->
      Sql.query!(db, """
          CREATE TABLE IF NOT EXISTS p2p_objects (
            key BLOB PRIMARY KEY,
            object BLOB
          )
      """)
    end)
  end

  def clear() do
    query!("DELETE FROM p2p_objects")
  end

  def append!(_key, _value) do
    throw(:not_implemented)
  end

  def maybe_update_object(key, encoded_object) when is_binary(encoded_object) do
    object = Object.decode!(encoded_object)
    maybe_update_object(key, object)
  end

  def maybe_update_object(key, object) when is_tuple(object) do
    hkey = Kademlia.hash(Object.key(object))
    # Checking that we got a valid object
    if key == nil or key == hkey do
      case object(hkey) do
        nil ->
          put_object(hkey, Object.encode!(object))

        existing ->
          existing_object = Object.decode!(existing)

          if Object.block_number(existing_object) < Object.block_number(object) do
            put_object(hkey, Object.encode!(object))
          end
      end
    end

    hkey
  end

  def put_object(key, object) do
    object = BertInt.encode!(object)
    query!("REPLACE INTO p2p_objects (key, object) VALUES(?1, ?2)", bind: [key, object])
  end

  def delete_object(key) do
    query!("DELETE FROM p2p_objects WHERE key = ?1", bind: [key])
  end

  def object(key) do
    Sql.fetch!(__MODULE__, "SELECT object FROM p2p_objects WHERE key = ?1", key)
  end

  def scan() do
    query!("SELECT key, object FROM p2p_objects")
    |> Enum.map(fn [key: key, object: obj] ->
      obj = BertInt.decode!(obj) |> Object.decode!()
      {key, obj}
    end)
  end

  @spec objects(integer, integer) :: any
  def objects(range_start, range_end) do
    bstart = <<range_start::integer-size(256)>>
    bend = <<range_end::integer-size(256)>>

    if range_start < range_end do
      query!("SELECT key, object FROM p2p_objects WHERE key >= ?1 AND key <= ?2",
        bind: [bstart, bend]
      )
    else
      query!("SELECT key, object FROM p2p_objects WHERE key >= ?1 OR key <= ?2",
        bind: [bstart, bend]
      )
    end
    |> Enum.map(fn [key: key, object: obj] -> {key, BertInt.decode!(obj)} end)
    |> Enum.filter(fn {key, value} ->
      # After a chain fork some signatures might have become invalid
      hash =
        Object.decode!(value)
        |> Object.key()
        |> Kademlia.hash()

      if key != hash do
        query!("DELETE FROM p2p_objects WHERE key = ?1", bind: [key])
        false
      else
        true
      end
    end)
  end
end
