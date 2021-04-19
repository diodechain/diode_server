# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.ChainSql do
  alias Model.Sql
  alias Model.Ets
  alias Chain.Transaction
  alias Chain.Block

  import Model.Sql
  # esqlite doesn't support :infinity
  @infinity 300_000_000

  defp fetch!(sql, param1 \\ nil) do
    fetch!(__MODULE__, sql, param1)
  end

  defp with_transaction(fun) do
    Sql.with_transaction(__MODULE__, fun)
  end

  def init() do
    Ets.init(__MODULE__)

    with_transaction(fn db ->
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
    with_transaction(fn db ->
      query!(db, "UPDATE blocks SET final = true WHERE hash = ?1", bind: [Block.hash(block)])
    end)
  end

  def set_normative_all() do
    peak = peak_block()

    with_transaction(fn db ->
      query!(db, "UPDATE blocks SET number = null", [])
      set_normative_all(db, peak)
    end)
  end

  defp set_normative_all(_db, nil) do
    :ok
  end

  defp set_normative_all(db, block) do
    put_block_number(__MODULE__, block)
    set_normative_all(db, Block.parent(block))
  end

  defp set_normative(db, block) do
    hash = Block.hash(block)

    case query!(db, "SELECT hash FROM blocks WHERE number = ?1", bind: [Block.number(block)]) do
      [[hash: ^hash]] ->
        :done

      [] ->
        put_block_number(db, block)
        set_normative(db, Block.parent(block))

      _others ->
        query!(db, "UPDATE blocks SET number = null WHERE number = ?1",
          bind: [Block.number(block)]
        )

        put_block_number(db, block)
        set_normative(db, Block.parent(block))
    end
  end

  defp put_block_number(db, block) do
    query!(db, "UPDATE blocks SET number = ?2 WHERE hash = ?1",
      bind: [Block.hash(block), Block.number(block)]
    )
  end

  def put_new_block(block) do
    with_transaction(fn db ->
      query(
        db,
        "INSERT OR FAIL INTO blocks (hash, parent, miner, data, state) VALUES(?1, ?2, ?3, ?4, ?5)",
        bind: [
          Block.hash(block),
          Block.parent_hash(block),
          Block.miner(block) |> Wallet.pubkey!(),
          Block.strip_state(block) |> BertInt.encode!(),
          prepare_state(block)
        ]
      )
      |> case do
        {:ok, _some} ->
          put_transactions(db, block)
          true

        {:error, _some} ->
          false
      end
    end)
  end

  @spec put_block(Chain.Block.t()) :: Chain.Block.t()
  def put_block(block) do
    with_transaction(fn db ->
      query(
        db,
        "REPLACE INTO blocks (hash, parent, miner, number, data, state) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        bind: [
          Block.hash(block),
          Block.parent_hash(block),
          Block.miner(block) |> Wallet.pubkey!(),
          Block.number(block),
          Block.strip_state(block) |> BertInt.encode!(),
          prepare_state(block)
        ]
      )
      |> case do
        {:ok, _some} ->
          put_transactions(db, block)
          true

        {:error, _some} ->
          false
      end
    end)

    block
  end

  def put_peak(block) do
    with_transaction(fn db ->
      put_new_block(block)

      query!(db, "UPDATE blocks SET number = null WHERE number >= ?1", bind: [Block.number(block)])

      put_block_number(db, block)
      set_normative(db, Block.parent(block))
    end)

    block
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
    # 25/05/2020: 5ms per execution
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
    with_transaction(fn db ->
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

  def all_block_hashes() do
    Sql.query!(__MODULE__, "SELECT hash, number FROM blocks WHERE number NOT NULL",
      call_timeout: @infinity
    )
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

    nr = Block.number(block)

    if nr > 0 and rem(nr, 100) == 1 do
      BertInt.encode!(state)
    else
      prev = nr - rem(nr, 100) + 1

      case Sql.query!(__MODULE__, "SELECT hash, state FROM blocks WHERE number = ?1", bind: [prev]) do
        [[hash: hash, state: bin]] ->
          prev_state = %Chain.State{} = BertInt.decode!(bin)

          {hash, Chain.State.difference(prev_state, state)}
          |> BertInt.encode!()

        [] ->
          BertInt.encode!(state)
      end
    end
  end
end
