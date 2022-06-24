# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.ChainSql do
  alias Model.{Ets, Sql, ChainSql.Writer}
  alias Chain.{Block, Transaction}
  require Logger

  import Model.Sql
  # esqlite doesn't support :infinity
  @infinity 300_000_000

  defmodule Writer do
    @moduledoc """
      Asynchonsouly writes new blocks
    """

    use GenServer
    alias Model.ChainSql
    alias Model.ChainSql.Writer
    defstruct blocks: [], db: nil

    def start_link([]) do
      GenServer.start_link(__MODULE__, %Writer{}, name: __MODULE__, hibernate_after: 5_000)
    end

    def submit_block_number(block_ref) do
      GenServer.cast(__MODULE__, {:submit, {:num, block_ref}})
    end

    def submit_new_block(block) do
      Ets.put(__MODULE__, Block.hash(block), block)

      if Ets.size(__MODULE__) > 24 do
        IO.puts("block write buffer pause")
        GenServer.call(__MODULE__, {:submit, {:hash, Block.hash(block)}}, :infinity)
      else
        GenServer.cast(__MODULE__, {:submit, {:hash, Block.hash(block)}})
      end
    end

    def query(hash) do
      Ets.lookup(__MODULE__, hash, fn -> ChainSql.query_block_by_hash(hash) end)
    end

    def peek(hash) do
      Ets.lookup(__MODULE__, hash)
    end

    def wait_for_flush(hash, from \\ "") do
      if peek(hash) != nil do
        Process.sleep(100)
        if from != nil, do: IO.puts("wait_for_flush #{from}")
        wait_for_flush(hash, nil)
      end
    end

    @impl true
    def init(state = %Writer{}) do
      # ensuring after a writer crash that all pending blocks are still
      # written
      for hash <- Ets.keys(__MODULE__) do
        GenServer.cast(__MODULE__, {:submit, {:hash, hash}})
      end

      {:ok, db} = Sql.start_database(Db.Default)
      {:ok, %Writer{state | db: db}}
    end

    @impl true
    def handle_call({:submit, block}, _from, state = %Writer{blocks: blocks}) do
      {:reply, :ok, write(%Writer{state | blocks: blocks ++ [block]})}
    end

    @impl true
    def handle_cast({:submit, block}, state = %Writer{blocks: blocks}) do
      {:noreply, write(%Writer{state | blocks: blocks ++ [block]})}
    end

    def handle_cast(:write, state) do
      {:noreply, write(state)}
    end

    defp write(state = %Writer{blocks: []}) do
      state
    end

    defp write(state = %Writer{blocks: [{:num, block_ref} | rest], db: db}) do
      ChainSql.do_put_block_number(db, block_ref)
      GenServer.cast(self(), :write)
      %Writer{state | blocks: rest}
    end

    defp write(state = %Writer{blocks: [{:block, block} | rest], db: db}) do
      ChainSql.do_put_new_block(db, block)
      Ets.remove(__MODULE__, Block.hash(block))
      GenServer.cast(self(), :write)
      %Writer{state | blocks: rest}
    end

    defp write(state = %Writer{blocks: [{:hash, hash} | rest], db: db}) do
      block = peek(hash)
      ChainSql.do_put_new_block(db, block)
      Ets.remove(__MODULE__, Block.hash(block))
      GenServer.cast(self(), :write)
      %Writer{state | blocks: rest}
    end
  end

  defp fetch!(sql, param1 \\ nil) do
    fetch!(__MODULE__, sql, param1)
  end

  def init() do
    Ets.init(Model.ChainSql.Writer)
    EtsLru.new(__MODULE__, 1024)

    with_transaction(__MODULE__, fn db ->
      query!(db, """
          CREATE TABLE IF NOT EXISTS blocks (
            hash BLOB PRIMARY KEY,
            miner BLOB,
            parent BLOB,
            number INTEGER NULL,
            final BOOL DEFAULT false,
            data BLOB,
            state BLOB
          )
      """)

      query!(db, """
          CREATE INDEX IF NOT EXISTS block_number ON blocks (
            number
          )
      """)

      query!(db, """
          CREATE INDEX IF NOT EXISTS block_parent ON blocks (
            parent
          )
      """)

      query!(db, """
          CREATE TABLE IF NOT EXISTS transactions (
            txhash BLOB PRIMARY KEY,
            blhash BLOB,
            FOREIGN KEY(blhash) REFERENCES blocks(hash) ON DELETE CASCADE
          )
      """)

      query!(db, """
          CREATE INDEX IF NOT EXISTS tx_block ON transactions (
            blhash
          )
      """)
    end)

    with %Chain.Block{} = block <- peak_block() do
      Model.SyncSql.clean_before(Chain.Block.number(block))
    end
  end

  def set_final(block) do
    with_transaction(__MODULE__, fn db ->
      query!(db, "UPDATE blocks SET final = true WHERE hash = ?1", bind: [Block.hash(block)])
    end)
  end

  def set_normative_all() do
    peak = peak_block()
    query!(__MODULE__, "UPDATE blocks SET number = null", [])
    set_normative_all(__MODULE__, peak)
  end

  defp set_normative_all(_db, nil) do
    :ok
  end

  defp set_normative_all(db, block_ref) do
    hash = BlockProcess.with_block(block_ref, &Block.number/1)
    Writer.wait_for_flush(hash, "set_normative_all")

    parent_hash =
      BlockProcess.with_block(block_ref, fn block ->
        do_put_block_number(db, block)
        Block.parent_hash(block)
      end)

    set_normative_all(db, parent_hash)
  end

  defp set_normative(db, block_ref) do
    {parent_hash, hash, number} =
      BlockProcess.with_block(block_ref, fn block ->
        {Block.parent_hash(block), Block.hash(block), Block.number(block)}
      end)

    Logger.debug("set_normative: #{number}")
    Writer.wait_for_flush(hash, "set_normative")

    case query!(db, "SELECT hash FROM blocks WHERE number = ?1", bind: [number]) do
      [[hash: ^hash]] ->
        :done

      [] ->
        BlockProcess.with_block(block_ref, fn block -> do_put_block_number(db, block) end)
        set_normative(db, parent_hash)

      _others ->
        query!(db, "UPDATE blocks SET number = null WHERE number = ?1", bind: [number])
        BlockProcess.with_block(block_ref, fn block -> do_put_block_number(db, block) end)
        set_normative(db, parent_hash)
    end
  end

  def put_block_number(block_ref) do
    Writer.submit_block_number(block_ref)
  end

  # public because the writer needs to call it
  def do_put_block_number(db, block_ref) do
    [hash, number] = BlockProcess.fetch(block_ref, [:hash, :number])
    # IO.puts("put_block_number(#{number})")
    query!(db, "UPDATE blocks SET number = ?2 WHERE hash = ?1", bind: [hash, number])
  end

  def put_new_block(block) do
    Writer.submit_new_block(block)
    true
  end

  def do_put_new_block(db, block) do
    {state, encoded_state} = prepare_state(block)

    ret =
      with_transaction(
        db,
        fn db ->
          query(
            db,
            "INSERT OR FAIL INTO blocks (hash, parent, miner, data, state) VALUES(?1, ?2, ?3, ?4, ?5)",
            bind: [
              Block.hash(block),
              Block.parent_hash(block),
              Block.miner(block) |> Wallet.pubkey!(),
              Block.strip_state(block) |> BertInt.encode!(),
              encoded_state
            ]
          )
          |> case do
            {:ok, _some} ->
              put_transactions(db, block)
              true

            {:error, _some} ->
              false
          end
        end
      )

    if ret, do: compress_state(db, block, state)
    ret
  end

  @spec put_block(Chain.Block.t()) :: Chain.Block.t()
  def put_block(block) do
    {state, encoded_state} = prepare_state(block)
    Writer.wait_for_flush(Block.hash(block), "put_block")

    with_transaction(
      __MODULE__,
      fn db ->
        query(
          db,
          "REPLACE INTO blocks (hash, parent, miner, number, data, state) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
          bind: [
            Block.hash(block),
            Block.parent_hash(block),
            Block.miner(block) |> Wallet.pubkey!(),
            Block.number(block),
            Block.strip_state(block) |> BertInt.encode!(),
            encoded_state
          ]
        )
        |> case do
          {:ok, _some} ->
            put_transactions(db, block)
            true

          {:error, _some} ->
            false
        end
      end
    )

    compress_state(__MODULE__, block, state)
    block
  end

  def put_peak(block_hash) do
    [number] = BlockProcess.fetch(block_hash, [:number])
    query!(__MODULE__, "DELETE FROM blocks WHERE number > ?1", bind: [number])
    set_normative(__MODULE__, block_hash)
  end

  defp put_transactions(db, block) do
    block_hash = Block.hash(block)

    for tx <- block.transactions do
      query(db, "INSERT INTO transactions (txhash, blhash) VALUES(?1, ?2)",
        bind: [Transaction.hash(tx), block_hash]
      )
    end
  end

  def block(number) when is_integer(number) do
    fetch!("SELECT data FROM blocks WHERE number = ?1", number)
  end

  def peak_block() do
    fetch!("SELECT data FROM blocks ORDER BY number DESC LIMIT 1")
  end

  def final_block() do
    fetch!("SELECT data FROM blocks WHERE final = true ORDER BY number DESC LIMIT 1")
  end

  def block_by_hash(hash) do
    Writer.query(hash)
  end

  def query_block_by_hash(hash) do
    fetch!("SELECT data FROM blocks WHERE hash = ?1", hash)
  end

  def blocks_by_hash(hash, count) when is_integer(count) do
    # 25/05/2020: 8ms with count=100 per execution
    query!(
      __MODULE__,
      """
      WITH RECURSIVE parents_of(n, level) AS (
        VALUES(?1, 0) UNION SELECT parent, parents_of.level+1 FROM blocks, parents_of
          WHERE blocks.hash=parents_of.n LIMIT #{count}
      )
      SELECT data FROM parents_of JOIN blocks WHERE hash=n ORDER BY level ASC
      """,
      bind: [hash]
    )
    |> Enum.map(fn [data: raw] -> BertInt.decode!(raw) end)
  end

  def blockquick_window(hash) do
    EtsLru.fetch(__MODULE__, {:blockquick_window, hash}, fn -> query_blockquick_window(hash) end)
  end

  def query_blockquick_window(hash) do
    case Writer.peek(hash) do
      nil ->
        do_query_blockquick_window(hash)

      block ->
        [_ | window] = blockquick_window(Block.parent_hash(block))
        window ++ [Block.coinbase(block)]
    end
  end

  defp do_query_blockquick_window(hash) do
    # 25/05/2020: 5ms per exec
    # IO.puts("do_query_blockquick_window: #{Base16.encode(hash)}")
    query!(
      __MODULE__,
      """
      WITH RECURSIVE parents_of(n, level) AS (
        VALUES(?1, 0) UNION SELECT parent, parents_of.level+1 FROM blocks, parents_of
          WHERE blocks.hash=parents_of.n LIMIT #{Chain.window_size()}
      )
      SELECT miner FROM parents_of JOIN blocks WHERE hash=n ORDER BY level DESC
      """,
      bind: [hash]
    )
    |> Enum.map(fn [miner: pubkey] ->
      Wallet.from_pubkey(pubkey) |> Wallet.address!() |> :binary.decode_unsigned()
    end)
  end

  def state(block_hash) do
    case fetch!("SELECT state FROM blocks WHERE hash = ?1", block_hash) do
      %Chain.State{} = state ->
        state

      {prev_hash, delta} ->
        Chain.State.apply_difference(state(prev_hash), delta)
    end
  end

  def block_by_txhash(txhash) do
    fetch!(
      "SELECT data FROM blocks WHERE hash = (SELECT blhash FROM transactions WHERE txhash = ?1)",
      txhash
    )
  end

  def truncate_blocks() do
    # Delete in this order to avoid cascading
    with_transaction(__MODULE__, fn db ->
      query!(db, "DELETE FROM transactions")
      query!(db, "DELETE FROM blocks")
    end)
  end

  def top_blocks(count) when is_integer(count) do
    Sql.query!(
      __MODULE__,
      "SELECT data FROM blocks WHERE number NOT NULL ORDER BY number DESC LIMIT #{count}",
      call_timeout: @infinity
    )
    |> Enum.map(fn [data: data] -> BertInt.decode!(data) end)
  end

  @splits 3
  def all_block_hashes() do
    case Sql.query!(__MODULE__, "SELECT MAX(number) as number FROM blocks") do
      [] ->
        []

      [[number: num]] ->
        size = ceil((num + 1) / @splits)

        Enum.map(0..(@splits - 1), fn n ->
          Task.async(fn -> select_hashes(n * size, (n + 1) * size) end)
        end)
        |> Task.await_many(:infinity)
        |> Stream.concat()
    end
  end

  def select_hashes(from, to) do
    {:ok, db} = Sql.start_database(Db.Default)

    ret =
      Sql.query!(
        db,
        "SELECT parent, hash, number FROM blocks WHERE number >= ?1 AND number < ?2 ORDER BY number",
        bind: [from, to]
      )

    Sqlitex.Server.stop(db)
    ret
  end

  def query!(sql) do
    Sql.query!(__MODULE__, sql)
  end

  def alt_blocks() do
    Sql.query!(__MODULE__, "SELECT data FROM blocks WHERE number IS NULL", call_timeout: @infinity)
    |> Enum.map(fn [data: data] -> BertInt.decode!(data) end)
  end

  def clear_alt_blocks() do
    Sql.query!(__MODULE__, "DELETE FROM blocks WHERE number IS NULL", call_timeout: @infinity)
    Sql.query!(__MODULE__, "PRAGMA OPTIMIZE", call_timeout: @infinity)
  end

  def transaction(txhash) do
    case block_by_txhash(txhash) do
      %Chain.Block{} = block -> Block.transaction(block, txhash)
      nil -> nil
    end
  end

  defp prepare_state(block) do
    state =
      %Chain.State{} =
      Block.state(block)
      |> Chain.State.compact()

    {state, BertInt.encode!(state)}
  end

  defp compress_state(db, block, state) do
    nr = Block.number(block)

    if nr > 0 and rem(nr, 100) == 1 do
      :nop
    else
      spawn_link(fn ->
        prev = nr - rem(nr, 100) + 1

        case Sql.query!(db, "SELECT hash, state FROM blocks WHERE number = ?1", bind: [prev]) do
          [[hash: hash, state: bin]] ->
            prev_state = %Chain.State{} = BertInt.decode!(bin)

            compressed_state =
              {hash, Chain.State.difference(prev_state, state)}
              |> BertInt.encode!()

            Sql.query_async!(db, "UPDATE blocks SET state = ?2 WHERE hash = ?1",
              bind: [Block.hash(block), compressed_state]
            )

          [] ->
            :nop
        end
      end)
    end
  end
end
