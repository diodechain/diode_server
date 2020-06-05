# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.BlockCache do
  alias Chain.BlockCache
  alias Model.Sql
  alias Chain.Block
  use GenServer

  defstruct blockquick_window: nil,
            difficulty: nil,
            total_difficulty: nil,
            epoch: nil,
            last_final: nil

  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  defp query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  defp query_async!(sql, params) do
    Sql.query_async!(__MODULE__, sql, params)
  end

  defp with_transaction(fun) do
    Sql.with_transaction(__MODULE__, fun)
  end

  def init(_) do
    with_transaction(fn db ->
      Sql.query!(db, """
          CREATE TABLE IF NOT EXISTS blockcache (
            hash BLOB PRIMARY KEY,
            data BLOB
          )
      """)
    end)

    __MODULE__ = :ets.new(__MODULE__, [:named_table, :compressed, :public])

    Enum.each(query!("SELECT hash, data FROM blockcache"), fn [hash: hash, data: data] ->
      :ets.insert(__MODULE__, {hash, BertInt.decode!(data)})
    end)

    {:ok, __MODULE__}
  end

  def handle_call({:do_cache, block}, _from, state) do
    {:reply, cache(block), state}
  end

  def reset() do
    query!("DELETE FROM blockcache")
    :ets.delete_all_objects(__MODULE__)
  end

  def warmup() do
    for n <- 0..Chain.peak() do
      if rem(n, 1000) == 0 do
        Diode.puts("Cache Warmup #{n}")
      end

      cache(Chain.block(n))
    end
  end

  def create_cache(block) do
    parent = Block.parent(block)

    %BlockCache{
      difficulty: Block.difficulty(block, parent),
      total_difficulty: Block.total_difficulty(block, parent),
      epoch: Block.epoch(block)
    }
  end

  # def cache(nil) do
  #   %Chain.BlockCache{}
  # end

  def cache?(block) do
    case Block.hash(block) do
      nil ->
        nil

      hash ->
        case :ets.lookup(__MODULE__, hash) do
          [{_hash, cache}] -> cache
          [] -> nil
        end
    end
  end

  def cache(block) do
    hash = Block.hash(block)

    case cache?(block) do
      nil ->
        if :erlang.whereis(__MODULE__) == self() do
          # :io.format("miss: ~p~n", [Base16.encode(hash)])
          put_cache(hash, create_cache(block))
        else
          GenServer.call(__MODULE__, {:do_cache, block}, 60_000)
        end

      cache ->
        cache
    end
  end

  def put_cache(nil, cache) do
    cache
  end

  def put_cache(hash, cache) do
    query_async!("REPLACE INTO blockcache (hash, data) VALUES(?1, ?2)",
      bind: [hash, BertInt.encode!(cache)]
    )

    :ets.insert(__MODULE__, {hash, cache})

    cache
  end

  defp do_get_cache(block, name) do
    do_get_cache(block, name, fn -> apply(Block, name, [block]) end)
  end

  defp do_get_cache(block, name, fun) do
    old_cache = cache(block)

    case Map.get(old_cache, name) do
      nil ->
        value = fun.()
        cache = Map.put(old_cache, name, value)
        # :io.format("put_cache (~p) => ~p~n~p~n", [name, old_cache, cache])
        put_cache(Block.hash(block), cache)
        value

      value ->
        value
    end
  end

  def difficulty(block) do
    cache(block).difficulty
  end

  def last_final(block) do
    hash = do_get_cache(block, :last_final, fn -> Block.last_final(block) |> Block.hash() end)
    final = Chain.block_by_hash(hash)
    # IO.puts("final #{Base16.encode(hash)} == #{Block.printable(final)}")
    final
  end

  def blockquick_window(block, parent \\ nil) do
    nr = Block.number(block)

    if nr > 100 and rem(nr, 10) == 1 do
      do_get_cache(block, :blockquick_window)
    else
      Block.blockquick_window(block, parent)
    end
  end

  def total_difficulty(block) do
    cache(block).total_difficulty
  end

  def epoch(block) do
    cache(block).epoch
  end

  #########################################################
  ####################### DELEGATES #######################
  #########################################################

  defdelegate create(parent, transactions, miner, time, trace? \\ false), to: Block
  defdelegate coinbase(block), to: Block
  defdelegate encode_transactions(transactions), to: Block
  defdelegate export(block), to: Block
  defdelegate extra_data(block), to: Block
  defdelegate gas_limit(block), to: Block
  defdelegate gas_price(block), to: Block
  defdelegate gas_used(block), to: Block
  defdelegate has_state?(block), to: Block
  defdelegate hash(block), to: Block
  defdelegate hash_in_target?(block, hash), to: Block
  defdelegate hash_target(block), to: Block
  defdelegate hash_valid?(block), to: Block
  defdelegate header(block), to: Block
  defdelegate in_final_window?(block), to: Block
  defdelegate increment_nonce(block), to: Block
  defdelegate set_timestamp(block, timestamp), to: Block
  defdelegate logs(block), to: Block
  defdelegate logs_bloom(block), to: Block
  defdelegate miner(block), to: Block
  defdelegate nonce(block), to: Block
  defdelegate number(block), to: Block
  defdelegate parent(block), to: Block
  defdelegate parent_hash(block), to: Block
  defdelegate printable(block), to: Block
  defdelegate receipts(block), to: Block
  defdelegate receiptsRoot(block), to: Block
  defdelegate sign(block, priv), to: Block
  defdelegate simulate(block), to: Block
  defdelegate size(block), to: Block
  defdelegate state(block), to: Block
  defdelegate state_hash(block), to: Block
  defdelegate strip_state(block), to: Block
  defdelegate timestamp(block), to: Block
  defdelegate transaction(block, hash), to: Block
  defdelegate transaction_gas(block, transaction), to: Block
  defdelegate transaction_index(block, transaction), to: Block
  defdelegate transaction_out(block, transaction), to: Block
  defdelegate transactions(block), to: Block
  defdelegate transaction_status(block, transaction), to: Block
  defdelegate txhash(block), to: Block
  defdelegate validate(block, parent), to: Block
  defdelegate valid?(block), to: Block
end
