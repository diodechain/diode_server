# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.BlockCache do
  alias Chain.{Block, BlockCache}
  alias Model.Sql
  use GenServer
  @timeout 60_000

  defstruct difficulty: nil,
            total_difficulty: nil,
            epoch: nil,
            last_final: nil

  defmodule Server do
    defstruct store_buffer: %{}
  end

  def start_link(ets_extra) do
    GenServer.start_link(__MODULE__, ets_extra, name: __MODULE__)
  end

  defp query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  defp with_transaction(fun) do
    Sql.with_transaction(__MODULE__, fun)
  end

  def init(ets_extra) do
    with_transaction(fn db ->
      Sql.query!(db, """
          CREATE TABLE IF NOT EXISTS blockcache (
            hash BLOB PRIMARY KEY,
            data BLOB
          )
      """)
    end)

    :timer.send_interval(1000, :flush)

    __MODULE__ = :ets.new(__MODULE__, [:named_table, :compressed, :public] ++ ets_extra)
    {:ok, %Server{}}
  end

  def handle_call({:do_cache, block}, _from, state) do
    {:reply, cache(block), state}
  end

  def handle_call({:do_cache!, {hash, cache}}, _from, state) do
    {:reply, put_cache(hash, cache), state}
  end

  def handle_cast({:store, hash, cache}, state = %Server{store_buffer: buffer}) do
    state = %Server{state | store_buffer: Map.put(buffer, hash, cache)}

    if map_size(buffer) > 100 do
      handle_info(:flush, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(:flush, state = %Server{store_buffer: []}) do
    {:noreply, state}
  end

  def handle_info(:flush, state = %Server{store_buffer: buffer}) do
    with_transaction(fn db ->
      for {hash, cache} <- buffer do
        Sql.query!(db, "REPLACE INTO blockcache (hash, data) VALUES(?1, ?2)",
          bind: [hash, BertInt.encode_zstd!(cache)]
        )
      end
    end)

    {:noreply, %Server{state | store_buffer: %{}}}
  end

  def reset() do
    query!("DELETE FROM blockcache")
    :ets.delete_all_objects(__MODULE__)
  end

  def warmup() do
    {hash, n} =
      BlockProcess.with_block(Chain.peak(), fn
        # nil -> {nil, nil}
        block -> {Block.hash(block), Block.number(block)}
      end)

    if fetch!(hash) == nil do
      warmup(0, div(n, 2), n)
    end
  end

  defp warmup(a, b, c) when a >= b - 1 or b + 1 >= c do
    peak = Chain.peak()

    for n <- a..peak do
      if n == a or rem(n, 1000) == 0 do
        IO.puts("BlockCache initialization #{n}/#{peak}")
      end

      cache = BlockProcess.with_block(n, fn block -> {Block.hash(block), create_cache(block)} end)
      GenServer.call(__MODULE__, {:do_cache!, cache}, @timeout)

      if n > 100 and rem(n, 1000) == 0 do
        last_final(n)
      end
    end
  end

  defp warmup(low, n, high) do
    if fetch!(Chain.blockhash(n)) == nil do
      warmup(low, div(n, 2), n)
    else
      warmup(n, n + div(high - n, 2), high)
    end
  end

  def create_cache(block) do
    %BlockCache{
      difficulty: Block.difficulty(block),
      total_difficulty: Block.total_difficulty(block),
      epoch: Block.epoch(block)
    }
  end

  # def cache(nil) do
  #   %Chain.BlockCache{}
  # end

  defp cache?(hash) do
    case hash do
      nil ->
        nil

      hash ->
        case :ets.lookup(__MODULE__, hash) do
          [{_hash, cache}] -> cache
          [] -> nil
        end
    end
  end

  defp fetch!(nil) do
    nil
  end

  defp fetch!(hash) do
    Sql.fetch!(__MODULE__, "SELECT data FROM blockcache WHERE hash = ?1", [hash])
  end

  def cache(nil), do: nil

  def cache(block_ref) do
    hash = BlockProcess.with_block(block_ref, &Block.hash/1)

    case cache?(hash) do
      nil ->
        case fetch!(hash) do
          nil ->
            put_cache(hash, BlockProcess.with_block(block_ref, &create_cache/1))

          data ->
            :ets.insert(__MODULE__, {hash, data})
            data
        end

      cache ->
        cache
    end
  end

  defp put_cache(hash, cache) do
    if hash != nil and cache != nil do
      :ets.insert(__MODULE__, {hash, cache})
      GenServer.cast(__MODULE__, {:store, hash, cache})
    end

    cache
  end

  defp do_get_cache(hash, name, fun) when is_binary(hash) do
    old_cache = cache(hash)

    case Map.get(old_cache, name) do
      nil ->
        value = fun.()
        cache = Map.put(old_cache, name, value)
        # :io.format("put_cache (~p) => ~p~n~p~n", [name, old_cache, cache])
        put_cache(hash, cache)
        value

      value ->
        value
    end
  end

  def difficulty(block) do
    cache(block).difficulty
  end

  def last_final(block_ref) when block_ref != nil do
    hash = BlockProcess.with_block(block_ref, &Block.hash/1)

    do_get_cache(hash, :last_final, fn ->
      BlockProcess.with_block(hash, &Block.last_final_hash/1)
    end)
  end

  def total_difficulty(hash) do
    case cache(hash) do
      %{total_difficulty: total_difficulty} -> total_difficulty
    end
  end

  def epoch(block) do
    cache(block).epoch
  end

  #########################################################
  ####################### DELEGATES #######################
  #########################################################

  defdelegate append_transaction(block, tx, trace? \\ false), to: Block
  defdelegate create(parent, transactions, miner, time, trace? \\ false), to: Block

  @spec create_empty(
          Chain.Block.t(),
          {:wallet, nil | <<_::256>>, nil | <<_::264>>, <<_::160>>},
          non_neg_integer
        ) :: Chain.Block.t()
  defdelegate create_empty(parent, miner, time), to: Block
  defdelegate coinbase(block), to: Block
  defdelegate encode_transactions(transactions), to: Block
  defdelegate export(block), to: Block
  defdelegate extra_data(block), to: Block
  defdelegate finalize_header(block), to: Block
  defdelegate gas_fees(block), to: Block
  defdelegate gas_limit(block), to: Block
  defdelegate gas_price(block), to: Block
  defdelegate gas_used(block), to: Block
  defdelegate hash(block), to: Block
  defdelegate hash_in_target?(block, hash), to: Block
  defdelegate hash_target(block), to: Block
  defdelegate hash_valid?(block), to: Block
  defdelegate header(block), to: Block
  defdelegate in_final_window?(block), to: Block
  defdelegate increment_nonce(block, n), to: Block
  defdelegate set_nonce(block, n), to: Block
  defdelegate set_timestamp(block, timestamp), to: Block
  defdelegate logs(block), to: Block
  defdelegate logs_bloom(block), to: Block
  defdelegate miner(block), to: Block
  defdelegate nonce(block), to: Block
  defdelegate number(block), to: Block
  defdelegate parent_hash(block), to: Block
  defdelegate printable(block), to: Block
  defdelegate receipts(block), to: Block
  defdelegate receipts_root(block), to: Block
  defdelegate sign(block, priv), to: Block
  defdelegate simulate(block), to: Block
  defdelegate size(block), to: Block
  defdelegate state(block), to: Block
  defdelegate state_hash(block), to: Block
  defdelegate state_tree(block), to: Block
  defdelegate strip_state(block), to: Block
  defdelegate timestamp(block), to: Block
  defdelegate transaction(block, hash), to: Block
  defdelegate transaction_gas(block, transaction), to: Block
  defdelegate transaction_index(block, transaction), to: Block
  defdelegate transaction_out(block, transaction), to: Block
  defdelegate transactions(block), to: Block
  defdelegate transaction_status(block, transaction), to: Block
  defdelegate txhash(block), to: Block
  defdelegate state_consistent?(block), to: Block
  defdelegate validate(block, fast), to: Block
  defdelegate ensure_state(block), to: Block
  defdelegate with_parent(block, fun), to: Block
end
