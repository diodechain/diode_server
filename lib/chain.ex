# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction
  alias Model.ChainSql
  require Logger
  use GenServer
  defstruct peak_hash: nil, peak_num: nil, by_hash: %{}, states: %{}

  @type t :: %Chain{
          peak_hash: binary(),
          peak_num: integer(),
          by_hash: %{binary() => Chain.Block.t()} | nil,
          states: map()
        }

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(ets_extra) do
    case GenServer.start_link(__MODULE__, ets_extra, name: __MODULE__, hibernate_after: 5_000) do
      {:ok, pid} ->
        Diode.puts("====== Chain    ======")
        Diode.puts("Peak  Block: #{with_peak(&Block.printable/1)}")
        Chain.BlockCache.warmup()
        Diode.puts("Final Block: #{with_final(&Block.printable/1)}")
        Diode.puts("")

        {:ok, pid}

      error ->
        error
    end
  end

  @spec init(any()) :: {:ok, Chain.t()}
  def init(ets_extra) do
    _create(ets_extra)
    BlockProcess.start_link()
    OnCrash.call(&on_crash/1)
    {:ok, load_blocks()}
  end

  @spec on_crash(any()) :: no_return()
  def on_crash(reason) do
    Logger.error("Chain exited with reason #{inspect(reason)}. Halting system")
    System.halt(1)
  end

  def window_size() do
    100
  end

  def genesis_hash() do
    case :persistent_term.get(:genesis_hash, nil) do
      nil ->
        hash = BlockProcess.with_block(0, &Block.hash/1)
        :persistent_term.put(:genesis_hash, hash)
        hash

      hash ->
        hash
    end
  end

  def sync() do
    call(fn state, _from -> {:reply, :ok, state} end)
  end

  @doc "Function for unit tests, replaces the current state"
  def set_state(state) do
    call(fn _state, _from ->
      {:reply, :ok, seed(state)}
    end)

    Chain.Worker.update_sync()
    :ok
  end

  @doc "Function for unit tests, resets state to genesis state"
  def reset_state() do
    set_state(genesis_state())
    Chain.BlockCache.reset()
  end

  def state() do
    state = call(fn state, _from -> {:reply, state, state} end)

    by_hash =
      Enum.map(blocks(state.peak_hash), fn block ->
        {Block.hash(block), Block.ensure_state(block)}
      end)
      |> Map.new()

    %{state | by_hash: by_hash}
  end

  defp call(fun, timeout \\ 25000) do
    GenServer.call(__MODULE__, {:call, fun}, timeout)
  end

  @doc "Gaslimit for block validation and estimation"
  def gas_limit() do
    20_000_000
  end

  @doc "GasPrice for block validation and estimation"
  def gas_price() do
    0
  end

  @spec average_transaction_gas() :: 200_000
  def average_transaction_gas() do
    200_000
  end

  def blocktime_goal() do
    15
  end

  def set_peak(%Chain.Block{} = block) do
    call(
      fn state, _from ->
        ChainSql.put_peak(block)
        ets_prefetch()
        block = ChainSql.peak_block()
        {:reply, :ok, %{state | peak_hash: Block.hash(block), peak_num: Block.number(block)}}
      end,
      :infinity
    )
  end

  def epoch() do
    case :persistent_term.get(:epoch, nil) do
      nil -> with_peak(&Block.epoch/1)
      num -> num
    end
  end

  def epoch_length() do
    if Diode.dev_mode?() do
      4
    else
      40320
    end
  end

  def with_final(fun) do
    final = with_peak(&Block.last_final/1, :infinity)
    # Block.last_final(peak_hash())
    BlockProcess.with_block(final, fun)
  end

  @spec peak_hash() :: binary()
  def peak_hash() do
    call(fn state, _from -> {:reply, state.peak_hash, state} end)
  end

  @spec peak() :: integer()
  def peak() do
    call(fn state, _from -> {:reply, state.peak_num, state} end)
  end

  def with_peak(fun, timeout \\ 120_000) do
    BlockProcess.with_block(peak(), fun, timeout)
  end

  def with_peak_state(fun) do
    BlockProcess.with_state(peak(), fun)
  end

  @spec blockhash(number()) :: binary() | nil
  def blockhash(n) do
    ets_lookup_hash(n)
  end

  @doc """
    Checks for existance of the given block. This is faster
    than using block_by_hash() as it can be fullfilled with
    a single ets lookoup and no need to ever fetch the full
    block.
  """
  @spec block_by_hash?(any()) :: boolean()
  def block_by_hash?(nil) do
    false
  end

  def block_by_hash?(hash) do
    case ets_lookup(hash) do
      nil -> false
      _ -> true
    end
  end

  def blocknumber(hash) do
    case ets_lookup(hash) do
      nil -> nil
      true -> BlockProcess.with_block(hash, &Block.number/1)
      nr when is_integer(nr) -> nr
    end
  end

  # returns all blocks from the current peak
  @spec blocks() :: Enumerable.t()
  def blocks() do
    blocks(peak_hash())
  end

  # returns all blocks from the given hash
  @spec blocks(Chain.Block.t() | binary()) :: Enumerable.t()
  def blocks(block_or_hash) do
    Stream.unfold([block_or_hash], fn
      [] ->
        nil

      [hash] when is_binary(hash) ->
        case ChainSql.blocks_by_hash(hash, 100) do
          [] -> nil
          [block | rest] -> {block, rest}
        end

      [block] ->
        case ChainSql.blocks_by_hash(Block.hash(block), 100) do
          [] -> nil
          [block | rest] -> {block, rest}
        end

      [block | rest] ->
        {block, rest}
    end)
  end

  @spec load_blocks() :: Chain.t()
  defp load_blocks() do
    case ChainSql.peak_block() do
      nil ->
        genesis_state() |> seed()

      _block ->
        ets_prefetch()
        block = ChainSql.peak_block()
        %Chain{peak_hash: Block.hash(block), peak_num: Block.number(block), by_hash: nil}
    end
  end

  defp seed(state) do
    ChainSql.truncate_blocks()

    Map.values(state.by_hash)
    |> Enum.each(fn block ->
      ChainSql.put_block(block)
    end)

    ets_prefetch()
    peak = ChainSql.peak_block()
    :persistent_term.put(:epoch, Block.epoch(peak))
    %Chain{peak_hash: Block.hash(peak), peak_num: Block.number(peak), by_hash: nil}
  end

  defp genesis_state() do
    {gen, parent} = genesis()
    hash = Block.hash(gen)
    phash = Block.hash(parent)

    %Chain{
      peak_hash: hash,
      peak_num: Block.number(gen),
      by_hash: %{hash => gen, phash => parent},
      states: %{}
    }
  end

  @spec add_block(binary(), boolean(), boolean()) :: :added | :stored
  def add_block(block_hash, relay \\ true, async \\ false) do
    [block_hash, parent_hash, number] =
      BlockProcess.fetch(block_hash, [:hash, :parent_hash, :number])

    cond do
      number < 1 ->
        IO.puts("Chain.add_block: Rejected invalid genesis block")
        :rejected

      true ->
        if async == false do
          ret =
            GenServer.call(__MODULE__, {:add_block, block_hash, parent_hash, relay}, :infinity)

          if ret == :added do
            Chain.Worker.update()
          end

          ret
        else
          GenServer.cast(__MODULE__, {:add_block, block_hash, parent_hash, relay})
          :unknown
        end
    end
  end

  def handle_cast({:add_block, block_hash, parent_hash, relay}, state) do
    {:reply, _reply, state} =
      handle_call({:add_block, block_hash, parent_hash, relay}, nil, state)

    {:noreply, state}
  end

  def handle_call(
        {:add_block, block_hash, parent_hash, relay},
        _from,
        state = %Chain{
          peak_hash: peak_hash
        }
      ) do
    Stats.tc(:addblock, fn ->
      [peak_info, peak_total_difficulty] =
        BlockProcess.fetch(peak_hash, [:printable, :total_difficulty])

      [info, total_difficulty] = BlockProcess.fetch(block_hash, [:printable, :total_difficulty])

      cond do
        peak_hash != parent_hash and total_difficulty <= peak_total_difficulty ->
          IO.puts("Chain.add_block: Extended   alt #{info} | (@#{peak_info}")
          {:reply, :stored, state}

        true ->
          # Update the state
          [number, epoch] = BlockProcess.fetch(block_hash, [:number, :epoch])

          if peak_hash == parent_hash do
            IO.puts("Chain.add_block: Extending main #{info}")

            Stats.incr(:block_cnt)
            ChainSql.put_block_number(block_hash)
            ets_add_placeholder(block_hash, number)
          else
            IO.puts("Chain.add_block: Replacing main #{info}")
            IO.puts("Old Peak: #{peak_info}: #{total_difficulty} > #{peak_total_difficulty}")

            # Recursively makes a new branch normative
            ChainSql.put_peak(block_hash)
            ets_refetch(block_hash, number)
          end

          state = %{state | peak_hash: block_hash, peak_num: number}
          :persistent_term.put(:epoch, epoch)

          # Printing some debug output per transaction
          if Diode.dev_mode?() do
            BlockProcess.with_block(block_hash, &print_transactions/1)
          end

          # Remove all transactions that have been processed in this block
          # from the outstanding local transaction pool
          BlockProcess.with_block(block_hash, &Chain.Pool.remove_transactions/1)

          # Let the ticketstore know the new block
          PubSub.publish(:rpc, {:rpc, :block, block_hash})

          if relay do
            [export, miner] = BlockProcess.fetch(block_hash, [:export, :miner])

            if Wallet.equal?(miner, Diode.miner()) do
              Kademlia.broadcast(export)
            else
              Kademlia.relay(export)
            end
          end

          {:reply, :added, state}
      end
    end)
  end

  def handle_call({:call, fun}, from, state) when is_function(fun) do
    fun.(state, from)
  end

  defp decode_blocks("") do
    []
  end

  defp decode_blocks(<<size::unsigned-size(32), block::binary-size(size), rest::binary>>) do
    [BertInt.decode!(block)] ++ decode_blocks(rest)
  end

  def import_blocks(filename, validate_fast? \\ false)

  def import_blocks(filename, validate_fast?) when is_binary(filename) do
    File.read!(filename)
    |> decode_blocks()
    |> import_blocks(validate_fast?)
  end

  def import_blocks(blocks, validate_fast?) do
    Stream.drop_while(blocks, fn block ->
      block_by_hash?(Block.hash(block))
    end)
    |> do_import_blocks(validate_fast?)
  end

  defp do_import_blocks(blocks, validate_fast?) do
    # replay block backup list
    lastblock =
      Enum.reduce_while(blocks, :ok, fn nextblock, _status ->
        block_hash = Block.hash(nextblock)

        if block_by_hash?(block_hash) do
          {:cont, block_hash}
        else
          Stats.tc(:vldt, fn -> Block.validate(nextblock, validate_fast?) end)
          |> case do
            <<block_hash::binary-size(32)>> ->
              add_block(block_hash, false, false)
              {:cont, block_hash}

            nonblock ->
              :io.format("Chain.import_blocks(2): Failed with ~p on: ~p~n", [
                nonblock,
                Block.printable(nextblock)
              ])

              {:halt, nonblock}
          end
        end
      end)

    finish_sync()
    lastblock
  end

  def is_active_sync(register \\ false) do
    me = self()

    case Process.whereis(:active_sync) do
      nil ->
        if register do
          Process.register(self(), :active_sync)
          PubSub.publish(:rpc, {:rpc, :syncing, true})
        end

        true

      ^me ->
        true

      _other ->
        false
    end
  end

  def throttle_sync(register \\ false, msg \\ "Syncing") do
    # For better resource usage we only let one process sync at full
    # throttle

    if is_active_sync(register) do
      :io.format("#{msg} ...~n")
    else
      :io.format("#{msg} (background worker) ...~n")
      Process.sleep(30_000)
    end
  end

  defp finish_sync() do
    if Process.whereis(:active_sync) != nil, do: Process.unregister(:active_sync)
    PubSub.publish(:rpc, {:rpc, :syncing, false})

    spawn(fn ->
      Model.SyncSql.clean_before(Chain.peak())
      Model.SyncSql.free_space()
    end)
  end

  def print_transactions(block) do
    for {tx, rcpt} <- Enum.zip([Block.transactions(block), Block.receipts(block)]) do
      status =
        case rcpt.msg do
          :evmc_revert -> ABI.decode_revert(rcpt.evmout)
          _ -> {rcpt.msg, rcpt.evmout}
        end

      Transaction.print(tx)
      IO.puts("\tStatus:      #{inspect(status)}")
    end

    IO.puts("")
  end

  def store_file(filename, term, overwrite \\ false) do
    if overwrite or not File.exists?(filename) do
      content = BertInt.encode!(term)

      with :ok <- File.mkdir_p(Path.dirname(filename)) do
        tmp = "#{filename}.#{:erlang.phash2(self())}"
        File.write!(tmp, content)
        File.rename!(tmp, filename)
      end
    end

    term
  end

  def load_file(filename, default \\ nil) do
    case File.read(filename) do
      {:ok, content} ->
        BertInt.decode_unsafe!(content)

      {:error, _} ->
        case default do
          fun when is_function(fun) -> fun.()
          _ -> default
        end
    end
  end

  defp genesis() do
    {Chain.GenesisFactory.testnet(), Chain.GenesisFactory.testnet_parent()}
  end

  #######################
  # ETS CACHE FUNCTIONS
  #######################
  defp ets_prefetch() do
    :persistent_term.put(:placeholder_complete, false)
    _clear()

    Diode.start_subwork("clearing alt blocks", fn ->
      ChainSql.clear_alt_blocks()
      # for block <- ChainSql.alt_blocks(), do: ets_add_alt(block)
    end)

    Diode.start_subwork("preloading hashes", fn ->
      _ =
        ChainSql.all_block_hashes()
        |> Enum.reduce_while(nil, fn
          {:prefetch, prefetch}, _prev ->
            :ets.insert(__MODULE__, prefetch)
            {:cont, nil}

          [parent: parent, hash: hash, number: number], prev ->
            if prev != nil and prev != parent do
              Diode.puts(
                "fixing inconsistent block #{number} #{Base16.encode(prev)} != #{Base16.encode(parent)} "
              )

              ChainSql.put_peak(prev)
              {:halt, prev}
            else
              ets_add_placeholder(hash, number)
              {:cont, hash}
            end
        end)

      :persistent_term.put(:placeholder_complete, true)
    end)
  end

  # Just fetching blocks of a newly adopted chain branch
  defp ets_refetch(nil, _) do
    :ok
  end

  defp ets_refetch(block_hash, number) do
    case do_ets_lookup(number) do
      [{^number, ^block_hash}] ->
        :ok

      other ->
        Logger.debug("ets_refetch(#{number}) -> #{inspect(other)}")
        ets_add_placeholder(block_hash, number)
        [parent_hash] = BlockProcess.fetch(block_hash, [:parent_hash])
        ets_refetch(parent_hash, number - 1)
    end
  end

  def ets_add_alt(block) do
    # block = Block.strip_state(block)
    _insert(Block.hash(block), true)
  end

  defp ets_add_placeholder(hash, number) do
    _insert2(hash, number)
  end

  def placeholder_complete() do
    :persistent_term.get(:placeholder_complete, false)
  end

  defp ets_lookup_hash(number) when is_integer(number) do
    case do_ets_lookup(number) do
      [] -> nil
      [{^number, block_hash}] -> block_hash
    end
  end

  defp ets_lookup(hash) when is_binary(hash) do
    case do_ets_lookup(hash) do
      [] -> nil
      [{^hash, num_or_true}] -> num_or_true
    end
  end

  defp do_ets_lookup(number) do
    _lookup(number)
    # Regularly getting output like this from the code below:
    # Slow ets lookup 16896
    # Slow ets lookup 10506

    # {time, ret} = :timer.tc(fn -> _lookup(number) end)

    # if time > 10000 do
    #   :io.format("Slow ets lookup ~p~n", [time])
    # end

    # ret
  end

  defp _create(ets_extra) do
    __MODULE__ =
      :ets.new(__MODULE__, [:named_table, :public, {:read_concurrency, true}] ++ ets_extra)
  end

  defp _lookup(number), do: :ets.lookup(__MODULE__, number)
  defp _insert(key, value), do: :ets.insert(__MODULE__, {key, value})
  defp _insert2(key, value), do: :ets.insert(__MODULE__, [{key, value}, {value, key}])
  defp _clear(), do: :ets.delete_all_objects(__MODULE__)
end
