# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction
  use GenServer
  defstruct peak: nil, by_hash: %{}, states: %{}

  @type t :: %Chain{
          peak: Chain.Block.t(),
          by_hash: %{binary() => Chain.Block.t()} | nil,
          states: Map.t()
        }

  @cache "chain.db"

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
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

    if store do
      store_file(Diode.dataDir(@cache), state(), true)
      Chain.BlockCache.save()
    end

    saver_loop()
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

  def handle_call({:call, fun}, from, state) when is_function(fun) do
    fun.(state, from)
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
    Block.number(peakBlock())
  end

  def epoch() do
    Block.epoch(peakBlock())
  end

  def epoch_length() do
    if Diode.dev_mode?() do
      4
    else
      40320
    end
  end

  @spec peakBlock() :: Chain.Block.t()
  def peakBlock() do
    call(fn state, _from -> {:reply, state.peak, state} end)
  end

  @spec peakState() :: Chain.State.t()
  def peakState() do
    Block.state(peakBlock())
  end

  @spec genesis_hash :: binary
  def genesis_hash() do
    Block.hash(Chain.block(0))
  end

  @spec block(number()) :: Chain.Block.t() | nil
  def block(n) do
    case :ets.lookup(__MODULE__, n) do
      [] -> nil
      [{^n, block}] -> block
    end
  end

  @spec block_by_hash(any()) :: Chain.Block.t() | nil
  def block_by_hash(nil) do
    nil
  end

  def block_by_hash(hash) do
    case :ets.lookup(__MODULE__, hash) do
      [] -> nil
      [{^hash, block}] -> block
    end
  end

  # returns all blocks from the current peak
  @spec blocks() :: Enumerable.t()
  def blocks() do
    blocks(Block.hash(peakBlock()))
  end

  # returns all blocks from the given hash
  @spec blocks(any()) :: Enumerable.t()
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
    %{chain | by_hash: nil}
  end

  # Seeds the ets table from a map
  defp seed_ets(state) do
    :ets.delete_all_objects(__MODULE__)
    seed_ets(state.by_hash, Block.hash(state.peak), map_size(state.by_hash) - 1)
  end

  defp seed_ets(_by_hash, nil, _n) do
    :ok
  end

  defp seed_ets(by_hash, hash, n) do
    block = by_hash[hash]
    :ets.insert(__MODULE__, {hash, block})
    :ets.insert(__MODULE__, {n, block})
    seed_ets(by_hash, Block.parent_hash(block), n - 1)
  end

  defp genesis_state() do
    gen = genesis()
    Store.set_block_transactions(gen)
    hash = Block.hash(gen)

    %Chain{
      peak: gen,
      by_hash: %{hash => gen},
      states: %{}
    }
  end

  @spec add_block(any()) :: :added | :stored
  def add_block(block, relay \\ true) do
    block_hash = Block.hash(block)

    if block_by_hash(block_hash) != nil do
      IO.puts("Chain.add_block: Skipping existing block")
      :added
    else
      number = Block.number(block)

      if number < 1 do
        IO.puts("Chain.add_block: Rejected invalid genesis block")
        :rejected
      else
        parent_hash = Block.parent_hash(block)
        do_add_block(block, number, parent_hash, block_hash, relay)
      end
    end
  end

  defp do_add_block(block, number, parent_hash, block_hash, relay) do
    prefix =
      Block.hash(block)
      |> binary_part(0, 5)
      |> Base16.encode(false)

    call(fn state, _from ->
      peak = state.peak
      totalDiff = Block.totalDifficulty(peak) + Block.difficulty(peak) * blockchainDelta()
      peak_hash = Block.hash(peak)
      author = Wallet.words(Block.miner(block))
      info = "chain ##{number}[#{prefix}] @#{author}"

      if peak_hash == parent_hash or Block.totalDifficulty(block) > totalDiff do
        if peak_hash == parent_hash do
          IO.puts("Chain.add_block: Extending main #{info}")
          Store.set_block_transactions(block)
        else
          IO.puts("Chain.add_block: Replacing main #{info}")
          Store.clear_transactions()

          :mnesia.transaction(fn ->
            Enum.each(blocks(block_hash), &Store.set_block_transactions/1)
          end)
        end

        # Printing some debug output per transaction
        if Diode.dev_mode?() do
          print_transactions(block)
        end

        # Update the state
        state = %{state | peak: block}
        :ets.insert(__MODULE__, {block_hash, block})
        :ets.insert(__MODULE__, {number, block})

        # Schedule a job to store the current state
        send(Chain.Saver, :store)
        # Remove all transactions that have been processed in this block
        # from the outstanding local transaction pool
        Chain.Pool.remove_transactions(block)

        # Let the ticketstore know the new block
        PubSub.publish(:rpc, {:rpc, :block, block})

        spawn(fn ->
          TicketStore.newblock()
        end)

        if relay do
          Kademlia.publish(block)
        end

        {:reply, :added, state}
      else
        IO.puts("Chain.add_block: Extending  alt #{info}")
        :ets.insert(__MODULE__, {block_hash, block})
        :ets.insert(__MODULE__, {number, block})
        {:reply, :stored, state}
      end
    end)
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

  @spec state_load(binary()) :: Chain.State.t()
  def state_load(state_hash) do
    case Process.get(:state_cache) do
      {^state_hash, state} ->
        state

      _ ->
        name = Base16.encode(state_hash)
        state = load_file("states/#{name}")
        Process.put(:state_cache, {state_hash, state})
        state
    end
  end

  @spec state_store(Chain.State.t()) :: Chain.State.t()
  def state_store(state) do
    name = Base16.encode(Chain.State.hash(state))
    store_file("states/#{name}", state)
  end

  defp genesis() do
    Chain.GenesisFactory.testnet()
  end
end

"""
for transaction validation:

// SendTransaction updates the pending block to include the given transaction.
// It panics if the transaction is invalid.
func (b *SimulatedBackend) SendTransaction(ctx context.Context, tx *types.Transaction) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	sender, err := types.Sender(types.HomesteadSigner{}, tx)
	if err != nil {
		panic(fmt.Errorf("invalid transaction: %v", err))
	}
	nonce := b.pendingState.GetNonce(sender)
	if tx.Nonce() != nonce {
		panic(fmt.Errorf("invalid transaction nonce: got %d, want %d", tx.Nonce(), nonce))
	}

	blocks, _ := core.GenerateChain(b.config, b.blockchain.CurrentBlock(), ethash.NewFaker(), b.database, 1, func(number int, block *core.BlockGen) {
		for _, tx := range b.pendingBlock.Transactions() {
			block.AddTx(tx)
		}
		block.AddTx(tx)
	})
	statedb, _ := b.blockchain.State()

	b.pendingBlock = blocks[0]
	b.pendingState, _ = state.New(b.pendingBlock.Root(), statedb.Database())
	return nil
}


sate_processor.go:

func ApplyTransaction(config *params.ChainConfig, bc *BlockChain, author *common.Address, gp *GasPool, statedb *state.StateDB, header *types.Header, tx *types.Transaction, usedGas *uint64, cfg vm.Config) (*types.Receipt, uint64, error) {
	msg, err := tx.AsMessage(types.MakeSigner(config, header.Number))
	if err != nil {
		return nil, 0, err
	}
	// Create a new context to be used in the EVM environment
	context := NewEVMContext(msg, header, bc, author)
	// Create a new environment which holds all relevant information
	// about the transaction and calling mechanisms.
	vmenv := vm.NewEVM(context, statedb, config, cfg)
	// Apply the transaction to the current state (included in the env)
	_, gas, failed, err := ApplyMessage(vmenv, msg, gp)
	if err != nil {
		return nil, 0, err
	}
	// Update the state with pending changes
	var root []byte
	if config.IsByzantium(header.Number) {
		statedb.Finalise(true)
	} else {
		root = statedb.IntermediateRoot(config.IsEIP158(header.Number)).Bytes()
	}
	*usedGas += gas

	// Create a new receipt for the transaction, storing the intermediate root and gas used by the tx
	// based on the eip phase, we're passing wether the root touch-delete accounts.
	receipt := types.NewReceipt(root, failed, *usedGas)
	receipt.TxHash = tx.Hash()
	receipt.GasUsed = gas
	// if the transaction created a contract, store the creation address in the receipt.
	if msg.To() == nil {
		receipt.ContractAddress = crypto.CreateAddress(vmenv.Context.Origin, tx.Nonce())
	}
	// Set the receipt logs and create a bloom for filtering
	receipt.Logs = statedb.GetLogs(tx.Hash())
	receipt.Bloom = types.CreateBloom(types.Receipts{receipt})

	return receipt, gas, err
}

"""
