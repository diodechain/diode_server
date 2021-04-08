# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.SyncSql do
  alias Model.SyncSql
  alias Model.Sql
  use GenServer
  require Logger

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
            BertInt.encode!(block)
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

  def handle_call({:search_parent, oblock}, _from, state = %SyncSql{queue: queue, cache: cache}) do
    block =
      if Map.has_key?(cache, Chain.Block.hash(oblock)) do
        Map.get(cache, Chain.Block.hash(oblock))
      else
        oblock
      end

    hash = Chain.Block.hash(block)

    {block2, state} =
      Sql.fetch!(
        __MODULE__,
        """
        SELECT data FROM blocks WHERE hash IN
        (
          WITH RECURSIVE parents_of(n) AS (
          VALUES(?1)
            UNION SELECT parent_hash FROM blocks, parents_of
            WHERE blocks.hash=n
          )
          SELECT n FROM parents_of
        )
        ORDER BY number ASC
        LIMIT 1;
        """,
        [hash]
      )
      |> case do
        nil ->
          if Map.has_key?(queue, hash) do
            {queue_top(block, queue), state}
          else
            send(state.worker, {:insert_block, block})
            queue = Map.put(queue, hash, block)
            {block, %SyncSql{state | queue: queue}}
          end

        other ->
          {queue_top(other, queue), state}
      end

    state =
      if Chain.Block.number(oblock) - Chain.Block.number(block2) > 1000 do
        %SyncSql{state | cache: Map.put(cache, Chain.Block.hash(oblock), block2)}
      else
        state
      end

    {:reply, block2, state}
  end

  defp queue_top(block, queue) do
    case Map.get(queue, Chain.Block.parent_hash(block)) do
      nil -> block
      parent -> queue_top(parent, queue)
    end
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
