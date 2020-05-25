defmodule Model.ChainSql do
  alias Model.Sql
  alias Model.Ets
  alias Chain.Transaction
  alias Chain.Block

  import Model.Sql

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
            data BLOB,
            FOREIGN KEY(blhash) REFERENCES blocks(hash) ON DELETE CASCADE
          )
      """)

      query!(db, """
          CREATE INDEX IF NOT EXISTS tx_block ON transactions (
            blhash
          )
      """)
    end)
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
    state_data = prepare_state(block)
    block_hash = Block.hash(block)
    data = Block.strip_state(block) |> BertInt.encode!()

    with_transaction(fn db ->
      ret =
        query(
          db,
          "INSERT OR FAIL INTO blocks (hash, parent, data, state) VALUES(?1, ?2, ?3, ?4)",
          bind: [block_hash, Block.parent_hash(block), data, state_data]
        )

      case ret do
        {:ok, _some} ->
          put_transactions(db, block)
          true

        {:error, _some} ->
          false
      end
    end)
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

  @spec put_block(Chain.Block.t()) :: Chain.Block.t()
  def put_block(block) do
    state_data = prepare_state(block)
    block_hash = Block.hash(block)
    data = Block.strip_state(block) |> BertInt.encode!()

    with_transaction(fn db ->
      ret =
        query(
          db,
          "REPLACE INTO blocks (hash, parent, number, data, state) VALUES(?1, ?2, ?3, ?4, ?5)",
          bind: [block_hash, Block.parent_hash(block), Block.number(block), data, state_data]
        )

      case ret do
        {:ok, _some} ->
          put_transactions(db, block)
          true

        {:error, _some} ->
          false
      end
    end)

    block
  end

  defp put_transactions(db, block) do
    block_hash = Block.hash(block)

    for tx <- block.transactions do
      txdata = BertInt.encode!(tx)

      query(db, "INSERT INTO transactions (txhash, blhash, data) VALUES(?1, ?2, ?3)",
        bind: [Transaction.hash(tx), block_hash, txdata]
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

  def all_blocks() do
    Sql.query!(__MODULE__, "SELECT data FROM blocks WHERE number NOT NULL ORDER BY number ASC",
      call_timeout: :infinity
    )
    |> Enum.map(fn [data: data] -> BertInt.decode!(data) end)
  end

  def alt_blocks() do
    Sql.query!(__MODULE__, "SELECT data FROM blocks WHERE number IS NULL", call_timeout: :infinity)
    |> Enum.map(fn [data: data] -> BertInt.decode!(data) end)
  end

  def clear_alt_blocks() do
    Sql.query!(__MODULE__, "DELETE FROM blocks WHERE number IS NULL", call_timeout: :infinity)
    Sql.query!(__MODULE__, "PRAGMA OPTIMIZE", call_timeout: :infinity)
  end

  def transaction(txhash) do
    fetch!("SELECT data FROM transactions WHERE txhash = ?1", txhash)
  end

  defp prepare_state(block) do
    state = %Chain.State{} = Block.state(block)
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
