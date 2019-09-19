defmodule Chain.Worker do
  alias Chain.BlockCache, as: Block
  use GenServer

  defstruct creds: nil,
            proposal: nil,
            parent_hash: nil,
            candidate: nil,
            target: 0,
            mode: 1,
            time: nil

  @type t :: %Chain.Worker{
          creds: Wallet.t(),
          proposal: [Chain.Transaction.t()],
          parent_hash: binary(),
          candidate: Chain.Block.t(),
          target: non_neg_integer(),
          mode: non_neg_integer() | :poll | :disabled
        }

  def candidate() do
    GenServer.call(__MODULE__, :candidate)
  end

  def work() do
    GenServer.call(__MODULE__, :work)
  end

  defp transactions(%Chain.Worker{proposal: proposal}), do: proposal
  defp parent_hash(%Chain.Worker{parent_hash: parent_hash}), do: parent_hash

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_mode) do
    GenServer.start_link(__MODULE__, Diode.workerMode(), name: __MODULE__)
  end

  def init(mode) do
    state = %Chain.Worker{creds: Store.wallet(), mode: mode}
    activate_timer(state)
    {:ok, state}
  end

  @spec update() :: :ok
  def update(), do: GenServer.cast(__MODULE__, :update)
  @spec set_mode(any()) :: :ok
  def set_mode(mode), do: GenServer.cast(__MODULE__, {:set_mode, mode})

  def handle_cast({:set_mode, mode}, state) do
    {:noreply, %{state | mode: mode}}
  end

  def handle_cast(:update, state) do
    {:noreply, do_update(state)}
  end

  defp do_update(state) do
    state2 = %{
      state
      | parent_hash: Block.hash(Chain.peakBlock()),
        proposal: Chain.Pool.proposal()
    }

    if state == state2 do
      state
    else
      if state.mode == :poll and state.proposal != [] do
        send(self(), :work)
      end

      %{state2 | candidate: nil}
    end
  end

  def handle_call(:candidate, _from, state) do
    state = generate_candidate(state)
    {:reply, state.candidate, state}
  end

  def handle_call(:work, _from, state) do
    {:reply, :ok, do_work(state)}
  end

  def handle_info(:work, state) do
    {:noreply, do_work(state)}
  end

  defp do_work(state) do
    state = generate_candidate(state)
    %{creds: creds, candidate: candidate} = state

    block =
      Enum.reduce_while(1..100, candidate, fn _, candidate ->
        candidate =
          Block.increment_nonce(candidate)
          |> Block.sign(creds)

        hash = Block.hash(candidate)

        if Block.hash_in_target?(candidate, hash) do
          {:halt, candidate}
        else
          {:cont, candidate}
        end
      end)

    hash = Block.hash(block)

    if Block.hash_in_target?(block, hash) and Chain.add_block(block) == :added do
      do_update(state)
    else
      %{state | candidate: block}
    end
    |> activate_timer()
  end

  defp generate_candidate(state = %{parent_hash: nil}) do
    parent_hash = Block.hash(Chain.peakBlock())
    generate_candidate(%{state | parent_hash: parent_hash})
  end

  defp generate_candidate(state = %{proposal: nil}) do
    generate_candidate(%{state | proposal: Chain.Pool.proposal()})
  end

  defp generate_candidate(state = %{candidate: nil, creds: creds}) do
    prev_hash = parent_hash(state)
    parent = %Chain.Block{} = Chain.block_by_hash(prev_hash)
    time = System.os_time(:second)
    miner = Wallet.address!(creds)
    account = Chain.State.ensure_account(Block.state(parent), miner)

    # Primary Registry call
    tx =
      %Chain.Transaction{
        nonce: Chain.Account.nonce(account),
        gasPrice: 0,
        gasLimit: 1_000_000_000,
        to: Diode.registryAddress(),
        data: ABI.encode_spec("blockReward")
      }
      |> Chain.Transaction.sign(Wallet.privkey!(creds))

    # Updating miner signed transaction nonces
    {txs, _} =
      Enum.reduce(transactions(state), {[tx], tx.nonce}, fn tx, {list, nonce} ->
        if Chain.Transaction.from(tx) == miner do
          tx = %{tx | nonce: nonce + 1} |> Chain.Transaction.sign(Wallet.privkey!(creds))
          {list ++ [tx], nonce + 1}
        else
          {list ++ [tx], nonce}
        end
      end)

    block = Block.create(parent, txs, creds, time)
    done = Block.transactions(block)

    if done != txs do
      failed = MapSet.difference(MapSet.new(txs), MapSet.new(done))
      keys = Enum.map(failed, &Chain.Transaction.hash/1)
      Chain.Pool.remove_transactions(keys)
    end

    diff = Block.difficulty(block)
    generate_candidate(%{state | candidate: block, target: diff, time: time})
  end

  defp generate_candidate(state) do
    state
  end

  defp activate_timer(state) do
    case state.mode do
      timeout when is_integer(timeout) ->
        # IO.puts("timer plus #{timeout}")
        Process.send_after(self(), :work, timeout)

      :poll ->
        if state.proposal != [] do
          send(self(), :work)
        end

      _default ->
        :ok
    end

    state
  end
end
