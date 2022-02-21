# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.Sql do
  # Automatically defines child_spec/1
  use Supervisor
  # esqlite doesn't support :infinity
  @infinity 300_000_000

  defp databases() do
    [
      {Db.Sync, "sync.sq3"},
      {Db.Cache, "cache.sq3"},
      {Db.Default, "blockchain.sq3"},
      {Db.Tickets, "tickets.sq3"},
      {Db.Creds, "wallet.sq3"}
    ]
  end

  defp map_mod(Chain.BlockCache), do: Db.Cache
  defp map_mod(Model.SyncSql), do: Db.Sync
  defp map_mod(Model.CredSql), do: Db.Creds
  defp map_mod(Model.TicketSql), do: Db.Tickets
  defp map_mod(Model.KademliaSql), do: Db.Tickets
  defp map_mod(pid) when is_pid(pid), do: pid
  defp map_mod(_), do: Db.Default

  def start_link() do
    Application.put_env(:sqlitex, :call_timeout, 300_000)
    {:ok, pid} = Supervisor.start_link(__MODULE__, [], name: __MODULE__)

    Model.MerkleSql.init()
    Model.ChainSql.init()
    Model.StateSql.init()
    Model.TicketSql.init()
    Model.KademliaSql.init()

    {:ok, pid}
  end

  defp init_connection(conn) do
    query!(conn, "PRAGMA journal_mode = WAL")
    query!(conn, "PRAGMA synchronous = NORMAL")
    # query!(conn, "PRAGMA OPTIMIZE", call_timeout: @infinity)
  end

  def init(_args) do
    File.mkdir(Diode.data_dir())

    children =
      databases()
      |> Keyword.keys()
      |> Enum.map(fn name ->
        %{id: name, start: {__MODULE__, :start_database, [name, name]}}
      end)

    children = children ++ [Model.CredSql, Model.SyncSql]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec start_database(atom(), atom() | nil) :: {:ok, pid()}
  def start_database(db, name \\ nil) do
    path =
      Keyword.fetch!(databases(), db)
      |> Diode.data_dir()
      |> to_charlist()

    opts = [name: name, db_timeout: @infinity, stmt_cache_size: 50]

    {:ok, pid} = Sqlitex.Server.start_link(path, opts)
    init_connection(pid)
    {:ok, pid}
  end

  def query(mod, sql, params \\ []) do
    params = Keyword.put_new(params, :call_timeout, @infinity)

    Stats.tc(:query, fn ->
      Sqlitex.Server.query(map_mod(mod), sql, params)
    end)
  end

  def query!(mod, sql, params \\ []) do
    {:ok, ret} = query(mod, sql, params)
    ret
  end

  def query_async!(mod, sql, params \\ []) do
    Sqlitex.Server.query_async(map_mod(mod), sql, params)
  end

  def fetch!(mod, sql, param1) do
    case lookup!(mod, sql, param1) do
      nil -> nil
      binary -> BertInt.decode!(binary)
    end
  end

  def lookup!(mod, sql, param1 \\ [], default \\ nil) do
    case query!(mod, sql, bind: List.wrap(param1)) do
      [] -> default
      [[{_key, value}]] -> value
    end
  end

  def with_transaction(mod, fun) do
    {:ok, result} = Sqlitex.Server.with_transaction(map_mod(mod), fun, call_timeout: @infinity)
    result
  end
end
