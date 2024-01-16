defmodule Mix.Tasks.Import do
  use Mix.Task

  @impl Mix.Task
  def run([from, to, source]) do
    :persistent_term.put(:env, :prod)
    from = String.to_integer(from)
    to = String.to_integer(to)
    {:ok, db} = Sqlitex.Server.start_link("data_prod/blockchain.sq3")
    {:ok, []} = Sqlitex.Server.query(db, "ATTACH ?1 AS src", bind: [source])

    Mix.Tasks.Export.import_loop(db, from, to)
  end

  def run(_) do
    Mix.shell().info("""
      SYNTAX:
      mix import <from> <to> <source>
    """)
  end
end
