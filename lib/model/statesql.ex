# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Model.StateSql do
  alias Model.Sql

  defp query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  def init() do
    EtsLru.new(__MODULE__, 1000)

    query!("""
        CREATE TABLE IF NOT EXISTS state_accounts (
          hash BLOB PRIMARY KEY,
          data BLOB
        )
    """)
  end

  def put_account(account) do
    key = Chain.Account.hash(account)
    data = BertInt.encode!(account)
    query!("INSERT OR IGNORE INTO state_accounts (hash, data) VALUES(?1, ?2)", bind: [key, data])
    EtsLru.put(__MODULE__, key, account)
    account
  end

  def account(nil) do
    nil
  end

  def account(key) do
    EtsLru.fetch(__MODULE__, key, fn ->
      [[data: data]] = query!("SELECT data FROM state_accounts WHERE hash = ?1", bind: [key])
      BertInt.decode!(data)
    end)
  end

  def all_keys() do
    query!("SELECT hash FROM state_accounts")
    |> Enum.map(fn [hash: key] -> key end)
  end
end
