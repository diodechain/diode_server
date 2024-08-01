defmodule Mix.Tasks.Export do
  use Mix.Task
  alias Model.ChainSql

  @impl Mix.Task
  def run([from, to, destination]) do
    :persistent_term.put(:env, :prod)
    from = String.to_integer(from)
    to = String.to_integer(to)
    {:ok, db} = Sqlitex.Server.start_link(destination)

    ChainSql.init_tables(db)
    {:ok, []} = Sqlitex.Server.query(db, "ATTACH \"data_prod/blockchain.sq3\" AS src")

    import_loop(db, from, to)
  end

  def run(_) do
    Mix.shell().info("""
      SYNTAX:
      mix export <from> <to> <destination>
    """)
  end

  def import_loop(db, from, to) do
    if from + 1000 < to do
      do_import(db, from, from + 1000)
      import_loop(db, from + 1001, to)
    else
      do_import(db, from, to)
    end
  end

  def do_import(db, from, to) do
    Mix.shell().info("Processing blocks #{from}-#{to}")

    {:ok, []} =
      Sqlitex.Server.query(
        db,
        "REPLACE INTO blocks SELECT * FROM src.blocks WHERE ?1 <= number AND number <= ?2",
        bind: [from, to]
      )

    {:ok, []} =
      Sqlitex.Server.query(
        db,
        "REPLACE INTO transactions SELECT txs.* FROM src.transactions AS txs JOIN src.blocks ON (blocks.hash = txs.blhash) WHERE ?1 <= number AND number <= ?2",
        bind: [from, to]
      )
  end
end
