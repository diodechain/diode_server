# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Model.KademliaSql do
  alias Model.Sql

  defp query!(sql, params \\ []) do
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

  def put_object(key, object) do
    object = BertInt.encode!(object)
    query!("REPLACE INTO p2p_objects (key, object) VALUES(?1, ?2)", bind: [key, object])
  end

  def object(key) do
    Sql.fetch!(__MODULE__, "SELECT object FROM p2p_objects WHERE key = ?1", key)
  end
end
