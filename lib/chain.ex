# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction
  alias Model.ChainSql
  use GenServer
  defstruct window: %{}, final: nil, peak: nil, by_hash: %{}, states: %{}

  @type t :: %Chain{
          window: %{binary() => integer()},
          final: Chain.Block.t(),
          peak: Chain.Block.t(),
          by_hash: %{binary() => Chain.Block.t()} | nil,
          states: Map.t()
        }

  @window_size 100
  @pregenesis "0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z"

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  @spec init(any()) :: {:ok, Chain.t()}
  def init(_) do
    ProcessLru.new(:blocks, 10)
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :public, {:read_concurrency, true}])
    state = load_blocks()

    Diode.puts("====== Chain    ======")
    Diode.puts("Peak  Block: #{Block.printable(state.peak)}")
    Diode.puts("Final Block: #{Block.printable(state.final)}")
    Diode.puts("")

    {:ok, state}
  end

  def pre_genesis_hash() do
    @pregenesis
  end

  def genesis_hash() do
    Block.hash(block(0))
  end

  def sync() do
    call(fn state, _from -> {:reply, :ok, state} end)
  end

  @doc "Function for unit tests, replaces the current state"
  def set_state(state) do
    call(fn _state, _from ->
      seed(state)
      {:reply, :ok, %{state | by_hash: nil}}
    end)

    Chain.Worker.update()
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
      Enum.map(blocks(Block.hash(state.peak)), fn block -> {Block.hash(block), block} end)
      |> Map.new()

    %{state | by_hash: by_hash}
  end

  defp call(fun, timeout \\ 5000) do
    GenServer.call(__MODULE__, {:call, fun}, timeout)
  end

  @doc "Gaslimit for block validation and estimation"
  def gasLimit() do
    100_000_000_000
  end

  @doc "GasPrice for block validation and estimation"
  def gas_price() do
    0
  end

  @spec averageTransactionGas() :: 200_000
  def averageTransactionGas() do
    200_000
  end

  def blocktimeGoal() do
    15
  end

  @spec blockchainDelta() :: 5
  def blockchainDelta() do
    5
  end

  @spec peak() :: integer()
  def peak() do
    Block.number(peak_block())
  end

  def epoch() do
    Block.epoch(peak_block())
  end

  def epoch_length() do
    if Diode.dev_mode?() do
      4
    else
      40320
    end
  end

  @spec final_block() :: Chain.Block.t()
  def final_block() do
    call(fn state, _from -> {:reply, state.final, state} end)
  end

  def set_final_block(%Chain.Block{} = block) do
    call(fn state, _from -> {:reply, :ok, set_final_block(state, block)} end)
  end

  defp set_final_block(state, %Chain.Block{} = block) do
    window = generate_blockquick_window(block)
    ChainSql.set_final(block)
    state = %{state | final: block, window: window}

    if is_final_tree?(state, state.peak) do
      state
    else
      ChainSql.put_peak(block)
      %{state | peak: block}
    end
  end

  @spec peak_block() :: Chain.Block.t()
  def peak_block() do
    call(fn state, _from -> {:reply, state.peak, state} end)
  end

  @spec peak_state() :: Chain.State.t()
  def peak_state() do
    Block.state(peak_block())
  end

  @spec block(number()) :: Chain.Block.t() | nil
  def block(n) do
    ets_lookup_idx(n, fn -> ChainSql.block(n) end)
  end

  @spec block_by_hash(any()) :: Chain.Block.t() | nil
  def block_by_hash(nil) do
    nil
  end

  def block_by_hash(hash) do
    Model.Stats.tc(:block_by_hash, fn ->
      do_block_by_hash(hash)
    end)
  end

  defp do_block_by_hash(hash) do
    ProcessLru.fetch(:blocks, hash, fn ->
      ets_lookup(hash, fn ->
        Model.Stats.tc(:sql_block_by_hash, fn ->
          ChainSql.block_by_hash(hash)
        end)
      end)
    end)
  end

  def block_by_txhash(txhash) do
    ChainSql.block_by_txhash(txhash)
  end

  def transaction(txhash) do
    ChainSql.transaction(txhash)
  end

  # returns all blocks from the current peak
  @spec blocks() :: Enumerable.t()
  def blocks() do
    blocks(Block.hash(peak_block()))
  end

  # returns all blocks from the given hash
  @spec blocks(any()) :: Enumerable.t()
  def blocks(%Chain.Block{} = block) do
    blocks(Block.hash(block))
  end

  def blocks(hash) do
    Stream.unfold(hash, fn hash ->
      case block_by_hash(hash) do
        nil -> nil
        block -> {block, Block.parent_hash(block)}
      end
    end)
  end

  @spec load_blocks() :: Chain.t()
  defp load_blocks() do
    chain =
      case ChainSql.peak_block() do
        nil ->
          genesis_state() |> seed()

        block ->
          ets_prefetch()
          %Chain{peak: block, final: ChainSql.final_block(), by_hash: nil}
      end

    case Map.get(chain, :final) do
      nil ->
        Map.put(chain, :final, nil)
        |> Map.put(:window, %{})

      final ->
        %{chain | window: generate_blockquick_window(final)}
    end
    |> update_blockquick(chain.peak)
  end

  defp seed(state) do
    ChainSql.truncate_blocks()

    Map.values(state.by_hash)
    |> Enum.each(fn block ->
      ChainSql.put_block(block)
    end)

    ets_prefetch()
    state
  end

  defp is_final_tree?(%Chain{final: nil}, _block) do
    # We don't have any final yet during bootstrap so let's pass all blocks
    true
  end

  defp is_final_tree?(chain = %Chain{final: final}, block) do
    cond do
      Block.hash(final) == Block.hash(block) -> true
      Block.number(final) >= Block.number(block) -> false
      true -> is_final_tree?(chain, Block.parent(block))
    end
  end

  def update_blockquick() do
    call(fn chain, _from ->
      {:reply, :ok, update_blockquick(chain, chain.peak)}
    end)

    final_block()
    |> Block.number()
  end

  defp update_blockquick(chain = %Chain{final: nil, peak: peak}, block) do
    if Block.number(peak) > @window_size do
      final = block(@window_size)
      update_blockquick(set_final_block(chain, final), block)
    else
      chain
    end
  end

  defp update_blockquick(chain = %Chain{final: final, window: window}, new_block) do
    scores = %{}
    threshold = div(@window_size, 2)

    ret =
      blocks(new_block)
      |> Enum.take(Block.number(new_block) - Block.number(final))
      |> Enum.reduce_while(scores, fn block, scores ->
        if Map.values(scores) |> Enum.sum() > threshold do
          {:halt, block}
        else
          miner = Block.coinbase(block)
          {:cont, Map.put(scores, miner, Map.get(window, miner, 0))}
        end
      end)

    case ret do
      new_final = %Chain.Block{} ->
        set_final_block(chain, new_final)

      _too_low_scores ->
        chain
    end
  end

  def generate_blockquick_window(final_block) do
    blocks(final_block)
    |> Enum.take(@window_size)
    |> Enum.reduce(%{}, fn block, scores ->
      Map.update(scores, Block.coinbase(block), 1, fn i -> i + 1 end)
    end)
  end

  defp genesis_state() do
    {gen, parent} = genesis()
    hash = Block.hash(gen)
    phash = Block.hash(parent)

    %Chain{
      peak: gen,
      by_hash: %{hash => gen, phash => parent},
      states: %{}
    }
  end

  @spec add_block(any()) :: :added | :stored
  def add_block(block, relay \\ true) do
    block_hash = Block.hash(block)
    true = Block.has_state?(block)

    cond do
      block_by_hash(block_hash) != nil ->
        IO.puts("Chain.add_block: Skipping existing block (2)")
        :added

      Block.number(block) < 1 ->
        IO.puts("Chain.add_block: Rejected invalid genesis block")
        :rejected

      true ->
        parent_hash = Block.parent_hash(block)

        GenServer.call(__MODULE__, {:add_block, block, parent_hash, relay})
    end
  end

  def handle_call({:add_block, block, parent_hash, relay}, _from, state) do
    peak = state.peak
    totalDiff = Block.totalDifficulty(peak) + Block.difficulty(peak) * blockchainDelta()
    peak_hash = Block.hash(peak)
    info = Block.printable(block)

    cond do
      not is_final_tree?(state, block) ->
        ChainSql.put_new_block(block)
        ets_add(block)
        IO.puts("Chain.add_block: Skipped    alt #{info} | (@#{Block.printable(peak)}")
        {:reply, :stored, state}

      peak_hash != parent_hash and Block.totalDifficulty(block) <= totalDiff ->
        ChainSql.put_new_block(block)
        ets_add(block)
        IO.puts("Chain.add_block: Extended   alt #{info} | (@#{Block.printable(peak)}")
        state = update_blockquick(state, block)
        # we're keeping peak constant here to obey Block.totalDifficulty(block) <= totalDiff
        {:reply, :stored, %{state | peak: peak}}

      true ->
        # Update the state
        if peak_hash == parent_hash do
          IO.puts("Chain.add_block: Extending main #{info}")

          Model.Stats.incr(:block)
          ChainSql.put_block(block)
          ets_add(block)
        else
          IO.puts("Chain.add_block: Replacing main #{info}")

          # Recursively makes a new branch normative
          ChainSql.put_peak(block)
          ets_prefetch()
        end

        state = update_blockquick(state, block)
        state = %{state | peak: block}

        # Printing some debug output per transaction
        if Diode.dev_mode?() do
          print_transactions(block)
        end

        # Remove all transactions that have been processed in this block
        # from the outstanding local transaction pool
        Chain.Pool.remove_transactions(block)

        # Let the ticketstore know the new block
        PubSub.publish(:rpc, {:rpc, :block, block})

        Debouncer.immediate(TicketStore, fn ->
          TicketStore.newblock(block)
        end)

        if relay do
          Kademlia.publish(block)
        end

        {:reply, :added, state}
    end
  end

  def handle_call({:call, fun}, from, state) when is_function(fun) do
    fun.(state, from)
  end

  def export_blocks(filename, blocks) do
    blocks =
      blocks
      |> Enum.map(&Block.export/1)
      |> Enum.filter(fn block -> Block.number(block) > 0 end)
      |> Enum.sort(fn a, b -> Block.number(a) < Block.number(b) end)

    File.write!(filename, BertInt.encode!(blocks))
  end

  def import_blocks(filename) when is_binary(filename) do
    File.read!(filename)
    |> BertInt.decode!()
    |> import_blocks()
  end

  def import_blocks([first | blocks]) do
    ProcessLru.new(:blocks, 10)

    case Block.validate(first) do
      %Chain.Block{} = block ->
        Chain.add_block(block, false)

        # replay block backup list
        Enum.reduce(blocks, block, fn nextblock, lastblock ->
          if lastblock != nil do
            ProcessLru.put(:blocks, Block.hash(lastblock), lastblock)
          end

          with %Chain.Block{} <- Block.parent(nextblock),
               block_hash <- Block.hash(nextblock) do
            case Chain.block_by_hash(block_hash) do
              %Chain.Block{} = existing ->
                existing

              nil ->
                ret =
                  Model.Stats.tc(:validate_time, fn ->
                    Block.validate(nextblock)
                  end)

                case ret do
                  %Chain.Block{} = block ->
                    throttle_sync(true)

                    Model.Stats.tc(:addblock_time, fn ->
                      Chain.add_block(block, false)
                    end)

                    block

                  _ ->
                    nil
                end
            end
          else
            nonblock ->
              :io.format("Chain.import_blocks: Expected parent but got ~p for ~p~n", [
                nonblock,
                nextblock
              ])

              throw(:sync_bug)
          end
        end)

        finish_sync()
        true

      nonblock ->
        :io.format("Chain.import_blocks: Failed with ~p~n", [nonblock])
        false
    end
  end

  def throttle_sync(register \\ false) do
    # For better resource usage we only let one process sync at full
    # throttle
    me = self()

    case Process.whereis(:active_sync) do
      nil ->
        if register do
          Process.register(self(), :active_sync)
          PubSub.publish(:rpc, {:rpc, :syncing, true})
        end

        :io.format("Syncing ...~n")

      ^me ->
        :io.format("Syncing ...~n")

      _other ->
        :io.format("Syncing slow ...~n")
        Process.sleep(1000)
    end
  end

  defp finish_sync() do
    if Process.whereis(:active_sync) == self() do
      Process.unregister(:active_sync)
      PubSub.publish(:rpc, {:rpc, :syncing, false})
      :io.format("Finished syncing!~n")
    end
  end

  def print_transactions(block) do
    for {tx, rcpt} <- Enum.zip([Block.transactions(block), Block.receipts(block)]) do
      status =
        case rcpt.msg do
          :evmc_revert -> ABI.decode_revert(rcpt.evmout)
          _ -> {rcpt.msg, rcpt.evmout}
        end

      hash = Base16.encode(Transaction.hash(tx))
      from = Base16.encode(Transaction.from(tx))
      to = Base16.encode(Transaction.to(tx))
      type = Atom.to_string(Transaction.type(tx))
      value = Transaction.value(tx)
      code = Base16.encode(Transaction.payload(tx))

      code =
        if byte_size(code) > 40 do
          binary_part(code, 0, 37) <> "... [#{byte_size(code)}]"
        end

      IO.puts("")
      IO.puts("\tTransaction: #{hash} Type: #{type}")
      IO.puts("\tFrom:        #{from} To: #{to}")
      IO.puts("\tValue:       #{value} Code: #{code}")
      IO.puts("\tStatus:      #{inspect(status)}")
    end

    IO.puts("")
  end

  @spec state(number()) :: Chain.State.t()
  def state(n) do
    Block.state(block(n))
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
  @ets_size 1000
  defp ets_prefetch() do
    :ets.delete_all_objects(__MODULE__)
    for block <- ChainSql.all_blocks(), do: ets_add(block)
    for block <- ChainSql.alt_blocks(), do: ets_add_alt(block)
  end

  defp ets_add_alt(block) do
    # block = Block.strip_state(block)
    :ets.insert(__MODULE__, {Block.hash(block), true})
  end

  defp ets_add(block) do
    # block = Block.strip_state(block)
    :ets.insert(__MODULE__, {Block.hash(block), block})
    :ets.insert(__MODULE__, {Block.number(block), Block.hash(block)})
    ets_remove_idx(Block.number(block) - @ets_size)
  end

  defp ets_remove_idx(idx) when idx <= 0 do
    :ok
  end

  defp ets_remove_idx(idx) do
    case do_ets_lookup(idx) do
      [{^idx, block_hash}] ->
        :ets.delete(__MODULE__, idx)
        :ets.insert(__MODULE__, {block_hash, true})

      _ ->
        nil
    end
  end

  defp ets_lookup_idx(idx, default) when is_integer(idx) do
    case do_ets_lookup(idx) do
      [] -> default.()
      [{^idx, block_hash}] -> block_by_hash(block_hash)
    end
  end

  defp ets_lookup(hash, default) when is_binary(hash) do
    case do_ets_lookup(hash) do
      [] -> nil
      [{^hash, true}] -> default.()
      [{^hash, block}] -> block
    end
  end

  defp do_ets_lookup(idx) do
    {time, ret} = :timer.tc(fn -> :ets.lookup(__MODULE__, idx) end)

    if time > 1000 do
      # :io.format("Slow ets lookup ~p~n", [time])

      if time > 10000 do
        :io.format("Slow ets lookup ~p~n", [time])
        # {:current_stacktrace, trace} = :erlang.process_info(self(), :current_stacktrace)
        # :io.format("~p~n", [trace])
      end
    end

    ret
  end
end
