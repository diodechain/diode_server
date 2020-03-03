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

  defp set_normative(db, block) do
    hash = Block.hash(block)

    case query!(db, "SELECT hash FROM blocks WHERE number = ?1", bind: [Block.number(block)]) do
      [[hash: ^hash]] ->
        :done

      _ ->
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
    state = %Chain.State{} = Block.state(block)
    state_data = BertInt.encode!(state)
    block_hash = Block.hash(block)
    data = Block.export(block) |> BertInt.encode!()

    with_transaction(fn db ->
      ret =
        query(
          db,
          "INSERT OR FAIL INTO blocks (hash, data, state) VALUES(?1, ?2, ?3)",
          bind: [block_hash, data, state_data]
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
    state = %Chain.State{} = Block.state(block)
    state_data = BertInt.encode!(state)
    block_hash = Block.hash(block)
    data = Block.export(block) |> BertInt.encode!()

    with_transaction(fn db ->
      ret =
        query(
          db,
          "REPLACE INTO blocks (hash, number, data, state) VALUES(?1, ?2, ?3, ?4)",
          bind: [block_hash, Block.number(block), data, state_data]
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
    fetch!("SELECT state FROM blocks WHERE hash = ?1", block_hash)
  end

  def block_by_txhash(txhash) do
    fetch!("SELECT blhash FROM transactions WHERE txhash = ?1", txhash)
  end

  def truncate_blocks() do
    # Delete in this order to avoid cascading
    with_transaction(fn db ->
      query!(db, "DELETE FROM transactions")
      query!(db, "DELETE FROM blocks")
    end)
  end

  def all_blocks() do
    Sql.query!(__MODULE__, "SELECT data FROM blocks WHERE number NOT NULL ORDER BY number ASC")
    |> Enum.map(fn [data: data] -> BertInt.decode!(data) end)
  end

  def alt_blocks() do
    Sql.query!(__MODULE__, "SELECT data FROM blocks WHERE number IS NULL")
    |> Enum.map(fn [data: data] -> BertInt.decode!(data) end)
  end

  def transaction(txhash) do
    fetch!("SELECT data FROM transactions WHERE txhash = ?1", txhash)
  end
end
