defmodule Mockchain.Worker do
  use GenServer

  defstruct creds: nil,
            proposal: nil,
            parent_hash: nil,
            candidate: nil,
            target: 0,
            mode: 1,
            time: nil

  @type t :: %Mockchain.Worker{
          creds: Wallet.t(),
          proposal: [Mockchain.Transaction.t()],
          parent_hash: binary(),
          candidate: Mockchain.Block.t(),
          target: non_neg_integer(),
          mode: non_neg_integer() | :poll | :disabled
        }

  def candidate() do
    GenServer.call(__MODULE__, :candidate)
  end

  defp transactions(%Mockchain.Worker{proposal: proposal}), do: proposal
  defp parent_hash(%Mockchain.Worker{parent_hash: parent_hash}), do: parent_hash

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_mode) do
    GenServer.start_link(__MODULE__, Diode.workerMode(), name: __MODULE__)
  end

  def init(mode) do
    state = %Mockchain.Worker{creds: Store.wallet(), mode: mode}
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
    state = %{
      state
      | parent_hash: Mockchain.Block.hash(Mockchain.peakBlock()),
        proposal: Mockchain.Pool.proposal(),
        candidate: nil
    }

    if state.mode == :poll and state.proposal != [] do
      send(self(), :work)
    end

    {:noreply, state}
  end

  def handle_call(:candidate, _from, state = %{candidate: nil}) do
    state = generate_candidate(state)
    {:reply, state.candidate, state}
  end

  def handle_call(:candidate, _from, state) do
    {:reply, state.candidate, state}
  end

  def handle_info(:work, state) do
    state = generate_candidate(state)
    %{creds: creds, candidate: candidate} = state

    block =
      Enum.reduce_while(1..100, candidate, fn _, candidate ->
        candidate = Mockchain.Block.sign(candidate, creds)
        hash = Mockchain.Block.hash(candidate)

        if Mockchain.Block.hash_in_target?(candidate, hash) do
          {:halt, candidate}
        else
          {:cont, candidate}
        end
      end)

    hash = Mockchain.Block.hash(block)

    if Mockchain.Block.hash_in_target?(block, hash) do
      if Mockchain.add_block(block) == :added do
        done = Mockchain.Block.transactions(block)
        keys = Enum.map(done, &Mockchain.Transaction.hash/1)
        Mockchain.Pool.remove_transactions(keys)
      end

      update()
    end

    activate_timer(state)
    {:noreply, %{state | candidate: block}}
  end

  defp generate_candidate(state = %{parent_hash: nil}) do
    parent_hash = Mockchain.Block.hash(Mockchain.peakBlock())
    generate_candidate(%{state | parent_hash: parent_hash})
  end

  defp generate_candidate(state = %{proposal: nil}) do
    generate_candidate(%{state | proposal: Mockchain.Pool.proposal()})
  end

  defp generate_candidate(state = %{candidate: nil, creds: creds}) do
    prev_hash = parent_hash(state)
    parent = %Mockchain.Block{} = Mockchain.block_by_hash(prev_hash)
    time = System.os_time(:second)
    account = Mockchain.State.ensure_account(Mockchain.peakState(), Wallet.address!(creds))

    tx =
      %Mockchain.Transaction{
        nonce: Mockchain.Account.nonce(account),
        gasPrice: 0,
        gasLimit: 1_000_000_000,
        to: Diode.registryAddress(),
        data: ABI.encode_spec("blockReward")
      }
      |> Mockchain.Transaction.sign(Wallet.privkey!(creds))

    txs = [tx | transactions(state)]
    block = Mockchain.Block.create(parent, txs, creds, time)
    done = Mockchain.Block.transactions(block)

    if done != txs do
      failed = MapSet.difference(MapSet.new(txs), MapSet.new(done))
      keys = Enum.map(failed, &Mockchain.Transaction.hash/1)
      Mockchain.Pool.remove_transactions(keys)
    end

    diff = Mockchain.Block.difficulty(block)
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
  end
end
