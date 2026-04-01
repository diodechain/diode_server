# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.SyncSql do
  alias Model.SyncSql
  alias Model.Sql
  use GenServer
  require Logger

  @parent_search_depth 10_000

  defstruct queue: %{}, worker: nil, cache: %{}

  defp query!(sql, params) do
    Sql.query!(__MODULE__, sql, bind: params)
  end

  defp with_transaction(fun) do
    Sql.with_transaction(__MODULE__, fun)
  end

  @spec start_link([]) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(_args) do
    with_transaction(fn db ->
      Sql.query!(db, """
          CREATE TABLE IF NOT EXISTS blocks (
            hash BLOB PRIMARY KEY,
            parent_hash BLOB,
            number INTEGER,
            data BLOB
          )
      """)
    end)

    {:ok, %SyncSql{worker: spawn_link(&worker/0)}}
  end

  # def fetch_block(hash) do
  #   Sql.fetch!(__MODULE__, "SELECT data FROM blocks WHERE hash = ?1", [hash])
  # end

  # def handle_cast({:insert_block, block}, state = %SyncSql{queue: queue, worker: worker}) do
  #   send(worker, {:insert_block, block})
  #   queue = Map.put(queue, Chain.Block.hash(block), block)
  #   {:noreply, %SyncSql{state | queue: queue}}
  # end

  def handle_cast({:done, hash}, state = %SyncSql{queue: queue}) do
    {:noreply, %SyncSql{state | queue: Map.delete(queue, hash)}}
  end

  defp worker_collect() do
    receive do
      {:insert_block, block} ->
        worker_collect([block])

      {:flush, from} ->
        send(from, :flush_done)
        worker_collect()
    end
  end

  defp worker_collect(blocks) when length(blocks) < 20 do
    receive do
      {:insert_block, block} ->
        worker_collect([block | blocks])

      {:flush, from} ->
        worker_flush(blocks)
        send(from, :flush_done)
        worker_collect()
    after
      1_000 -> blocks
    end
  end

  defp worker_collect(blocks) do
    blocks
  end

  defp worker_flush(blocks) do
    with_transaction(fn db ->
      Enum.each(blocks, fn block ->
        Sql.query!(
          db,
          "INSERT INTO blocks (hash, parent_hash, number, data) VALUES(?1, ?2, ?3, ?4)",
          bind: [
            Chain.Block.hash(block),
            Chain.Block.parent_hash(block),
            Chain.Block.number(block),
            BertInt.encode_zstd!(block)
          ]
        )
      end)
    end)

    Enum.each(blocks, fn block ->
      GenServer.cast(__MODULE__, {:done, Chain.Block.hash(block)})
    end)
  end

  def worker() do
    blocks = worker_collect()
    worker_flush(blocks)
    worker()
  end

  def search_parent(block) do
    GenServer.call(__MODULE__, {:search_parent, block}, :infinity)
  end

  def clean_before(peaknumber) do
    query!("DELETE FROM blocks WHERE number < ?1", [peaknumber])
  end

  def free_space() do
    query!("VACUUM", [])
  end

  def handle_call(
        {:resolve, %{oldest: _oldest, peak: peak}},
        _from,
        state = %SyncSql{worker: worker}
      ) do
    send(worker, {:flush, self()})

    receive do
      :flush_done -> :ok
    end

    ret =
      query!(
        """
        SELECT hash FROM blocks WHERE hash IN
        (
          WITH RECURSIVE parents_of(n) AS (
          VALUES(?1)
            UNION SELECT parent_hash FROM blocks, parents_of
            WHERE blocks.hash=n
          )
          SELECT n FROM parents_of
        )
        ORDER BY number ASC
        """,
        [Chain.Block.hash(peak)]
      )

    {:reply, ret, state}
  end

  def handle_call({:search_parent, oblock}, _from, state) do
    {block2, state} = search_parent(state, oblock, oblock)
    {:reply, block2, state}
  end

  defp search_parent(state, oblock, block) do
    hash = Chain.Block.hash(block)

    case Map.get(state.cache, hash) do
      nil ->
        parent_search_depth =
          @parent_search_depth + rem(Chain.Block.number(block), @parent_search_depth)

        case fetch_ancestor_within_depth(hash, parent_search_depth) do
          nil ->
            search_parent_missing_in_db(state, block, hash)

          {ancestor, depth} ->
            ancestor2 = queue_top(ancestor, state.queue)

            Logger.info(
              "SyncSql: search_parent query found ancestor: #{Chain.Block.number(ancestor2)}"
            )

            state =
              if rem(Chain.Block.number(ancestor2), 1000) == 0 do
                %SyncSql{state | cache: Map.put(state.cache, hash, ancestor2)}
              else
                state
              end

            if depth == parent_search_depth do
              search_parent(state, oblock, ancestor2)
            else
              {ancestor2, state}
            end
        end

      cached ->
        search_parent(state, oblock, cached)
    end
  end

  defp fetch_ancestor_within_depth(hash, max_depth) do
    sql = """
    WITH RECURSIVE parents_of(n, depth) AS (
      VALUES(?1, 0)
      UNION ALL
      SELECT b.parent_hash, p.depth + 1
      FROM blocks b, parents_of p
      WHERE b.hash = p.n AND p.depth < ?2 AND b.parent_hash IS NOT NULL
    ),
    picked AS (
      SELECT blocks.data AS data, parents_of.depth AS depth
      FROM blocks
      INNER JOIN parents_of ON blocks.hash = parents_of.n
      ORDER BY blocks.number ASC
      LIMIT 1
    )
    SELECT data, depth FROM picked
    """

    case Sql.query!(__MODULE__, sql, bind: [hash, max_depth]) do
      [] ->
        nil

      [row] ->
        {BertInt.decode!(row[:data]), row[:depth]}
    end
  end

  defp search_parent_missing_in_db(state = %SyncSql{queue: queue}, block, hash) do
    if Map.has_key?(queue, hash) do
      {queue_top(block, queue), state}
    else
      send(state.worker, {:insert_block, block})
      queue = Map.put(queue, hash, block)
      {block, %SyncSql{state | queue: queue}}
    end
  end

  defp queue_top(block, queue) do
    case Map.get(queue, Chain.Block.parent_hash(block)) do
      nil -> block
      parent -> queue_top(parent, queue)
    end
  end

  def count(nil) do
    0
  end

  def count(%{oldest: oldest, peak: peak}) do
    Chain.Block.number(peak) - Chain.Block.number(oldest)
  end

  def resolve(nil) do
    []
  end

  def resolve(blocks) do
    GenServer.call(__MODULE__, {:resolve, blocks}, :infinity)
    |> Stream.map(fn [hash: hash] ->
      Sql.fetch!(__MODULE__, "SELECT data FROM blocks WHERE hash=?1", [hash])
    end)
    # Cause we select .parent_hash the corresponding data will not be present for the
    # first block
    |> Stream.drop_while(fn block -> block == nil end)
    # Buffering 100 blocks each
    |> Stream.chunk_every(100)
    |> Stream.flat_map(fn chunk -> chunk end)
  end
end
