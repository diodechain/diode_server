# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction
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
  @cache "chain.db"
  @pregenesis "0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z"

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  @spec init(any()) :: {:ok, Chain.t()}
  def init(_) do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :compressed, :public])
    state = load_blocks()
    spawn_link(&saver_loop/0) |> Process.register(Chain.Saver)

    {:ok, state}
  end

  @spec saver_loop :: no_return
  def saver_loop() do
    :erlang.garbage_collect()
    Process.send_after(self(), :tick, 5000)
    store = saver_loop_wait(false)

    if store and not Diode.syncing?() do
      store_file(Diode.dataDir(@cache), state(), true)
      Chain.BlockCache.save()
    end

    saver_loop()
  end

  def pre_genesis_hash() do
    @pregenesis
  end

  def genesis_hash() do
    Block.hash(block(0))
  end

  defp saver_loop_wait(store) do
    receive do
      :store ->
        saver_loop_wait(true)

      :tick ->
        store
    end
  end

  def sync() do
    call(fn state, _from -> {:reply, :ok, state} end)
  end

  @doc "Function for unit tests, replaces the current state"
  def set_state(state) do
    call(fn _state, _from ->
      seed_ets(state)
      {:reply, :ok, %{state | by_hash: nil}}
    end)

    Store.seed_transactions(state.by_hash |> Map.values())
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
    window = generate_blockquick_window(block)
    call(fn state, _from -> {:reply, :ok, %{state | final: block, window: window}} end)
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
    [{^n, block}] = :ets.lookup(__MODULE__, n)
    block
  end

  @spec block_by_hash(any()) :: Chain.Block.t() | nil
  def block_by_hash(nil) do
    nil
  end

  def block_by_hash(hash) do
    case :ets.lookup(__MODULE__, hash) do
      [] ->
        nil

      [{^hash, block}] ->
        block
    end
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
    chain = %Chain{} = load_file(Diode.dataDir(@cache), &genesis_state/0)
    seed_ets(chain)
    chain = %{chain | by_hash: nil}

    if Map.get(chain, :final, nil) == nil do
      Map.put(chain, :final, nil)
      |> Map.put(:window, %{})
    else
      chain
    end
    |> update_blockquick(chain.peak)
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

  defp update_blockquick(chain = %Chain{final: nil, peak: peak}, block) do
    if Block.number(peak) > @window_size do
      final = block(@window_size)
      window = generate_blockquick_window(final)
      update_blockquick(%{chain | final: final, window: window}, block)
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
        %{chain | final: new_final, window: generate_blockquick_window(new_final)}

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

  # Seeds the ets table from a map
  defp seed_ets(state) do
    :ets.delete_all_objects(__MODULE__)

    Map.values(state.by_hash)
    |> Enum.each(&insert_ets/1)
  end

  defp insert_ets(block) do
    :ets.insert(__MODULE__, {Block.hash(block), block})
    :ets.insert(__MODULE__, {Block.number(block), block})
  end

  defp genesis_state() do
    {gen, parent} = genesis()
    Store.set_block_transactions(gen)
    Store.set_block_transactions(parent)
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

      false == :ets.insert_new(__MODULE__, {block_hash, block}) ->
        IO.puts("Chain.add_block: Skipping existing block (3)")
        :stored

      true ->
        parent_hash = Block.parent_hash(block)

        # Ensure the block state is on disk
        block = Chain.Block.store(block)

        GenServer.call(__MODULE__, {:add_block, block, parent_hash, block_hash, relay})
    end
  end

  def handle_call({:add_block, block, parent_hash, block_hash, relay}, _from, state) do
    peak = state.peak
    totalDiff = Block.totalDifficulty(peak) + Block.difficulty(peak) * blockchainDelta()
    peak_hash = Block.hash(peak)

    author = Wallet.words(Block.miner(block))

    prefix =
      block_hash
      |> binary_part(0, 5)
      |> Base16.encode(false)

    info = "chain ##{Block.number(block)}[#{prefix}] @#{author}"

    cond do
      not is_final_tree?(state, block) ->
        IO.puts("Chain.add_block: Skipped    alt #{info}")
        {:reply, :stored, state}

      peak_hash != parent_hash and Block.totalDifficulty(block) <= totalDiff ->
        IO.puts("Chain.add_block: Extended   alt #{info}")
        state = update_blockquick(state, block)
        {:reply, :stored, state}

      true ->
        state = update_blockquick(state, block)
        # Update the state
        state = %{state | peak: block}
        insert_ets(block)

        if peak_hash == parent_hash do
          IO.puts("Chain.add_block: Extending main #{info}")
          Store.set_block_transactions(block)
        else
          IO.puts("Chain.add_block: Replacing main #{info}")

          # When the blockchain was shorted delete cache > new block
          if Block.number(peak) > Block.number(block) do
            for num <- (Block.number(block) + 1)..Block.number(peak) do
              :ets.delete(__MODULE__, num)
            end
          end

          # Rewrite transactions and block numbers <= new block
          Store.clear_transactions()

          Enum.each(blocks(block_hash), fn block ->
            insert_ets(block)

            {:atomic, :ok} =
              :mnesia.transaction(fn ->
                Store.set_block_transactions(block)
              end)
          end)
        end

        # Printing some debug output per transaction
        if Diode.dev_mode?() do
          print_transactions(block)
        end

        # Schedule a job to store the current state
        send(Chain.Saver, :store)
        # Remove all transactions that have been processed in this block
        # from the outstanding local transaction pool
        Chain.Pool.remove_transactions(block)

        # Let the ticketstore know the new block
        PubSub.publish(:rpc, {:rpc, :block, block})

        Debounce.immediate(TicketStore, fn ->
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

  @doc """
    reseed is a debugging function
  """
  def reseed() do
    Enum.each(blocks(), fn block ->
      n = Block.number(block)

      case :ets.lookup(__MODULE__, n) do
        [] ->
          :io.format("reseeding ~p ~p~n", [n, Block.hash(block)])
          insert_ets(block)

        [{^n, ^block}] ->
          :ok

        [{^n, other}] ->
          :io.format("reseeding wrong ~p ~p != ~p~n", [n, Block.hash(block), Block.hash(other)])
          # :io.format("~180p~n~180p~n", [block, other])
          insert_ets(block)
      end
    end)
  end
end
