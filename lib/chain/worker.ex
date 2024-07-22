# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Worker do
  require Logger
  alias Chain.Worker
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction
  use GenServer

  defstruct creds: nil,
            proposal: nil,
            parent_hash: nil,
            min_fee: 0,
            candidate: nil,
            target: 0,
            mode: 75,
            working: false

  @type t :: %Chain.Worker{
          creds: Wallet.t(),
          proposal: [Transaction.t()],
          parent_hash: binary(),
          min_fee: non_neg_integer(),
          candidate: Chain.Block.t(),
          target: non_neg_integer(),
          mode: non_neg_integer() | :poll | :disabled,
          working: boolean()
        }

  def with_candidate(fun) do
    GenServer.call(__MODULE__, {:with_candidate, fun})
  end

  def work() do
    if Diode.dev_mode?() do
      ret = GenServer.call(__MODULE__, :update_work)
      GenServer.call(__MODULE__, :sync)
      ret
    else
      GenServer.call(__MODULE__, :work)
    end
  end

  defp parent_hash(%Chain.Worker{parent_hash: parent_hash}), do: parent_hash

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_mode) do
    GenServer.start_link(__MODULE__, Diode.worker_mode(), name: __MODULE__)
  end

  def init(mode) do
    OnCrash.call(fn reason ->
      if reason not in [:normal, :shutdown] do
        Logger.error("Worker crashed.. flushing tx pool...")
        Chain.Pool.flush()
      end
    end)

    state = %Chain.Worker{creds: Diode.miner(), mode: mode}
    :erlang.process_flag(:priority, :low)
    {:ok, _ref} = :timer.send_interval(100, :sleep)

    if mode not in [:poll, :disabled] do
      :timer.send_after(5_000, :work)
    end

    {:ok, state}
  end

  def hashrate() do
    Stats.get(:hashrate, 0)
  end

  @spec update() :: :ok
  def update() do
    Debouncer.immediate(Chain.Worker, fn ->
      GenServer.cast(Chain.Worker, :update)
    end)
  end

  @spec update_sync() :: :ok
  def update_sync() do
    GenServer.call(Chain.Worker, :update)
  end

  @spec set_mode(any()) :: :ok
  def set_mode(mode), do: GenServer.cast(__MODULE__, {:set_mode, mode})
  def mode(), do: GenServer.call(__MODULE__, :mode)

  def handle_cast({:set_mode, mode}, state) do
    {:noreply, %{state | mode: mode, parent_hash: nil}}
  end

  def handle_cast(:update, state) do
    {:noreply, do_update(state)}
  end

  defp do_update(state) do
    state2 = update_parent(state)

    if state == state2 do
      state
    else
      %{activate_timer(state2) | candidate: nil}
    end
  end

  defp update_parent(state = %Worker{parent_hash: hash, min_fee: fee}) do
    [new_hash, parent_number] = BlockProcess.fetch(Chain.peak(), [:hash, :number])

    fee =
      if hash == new_hash do
        fee
      else
        if ChainDefinition.min_transaction_fee(parent_number + 1) do
          BlockProcess.with_block(new_hash, fn parent ->
            Contract.Registry.min_transaction_fee(parent)
          end)
        else
          0
        end
      end

    txs = Enum.filter(Chain.Pool.proposal(), fn tx -> Transaction.gas_price(tx) >= fee end)

    %Worker{
      state
      | parent_hash: new_hash,
        proposal: txs,
        min_fee: fee
    }
  end

  def handle_call({:with_candidate, fun}, _from, state) do
    state = generate_candidate(state)
    {:reply, fun.(state.candidate), state}
  end

  def handle_call(:sync, _from, state) do
    Chain.sync()
    {:reply, :ok, state}
  end

  def handle_call(:update, _from, state) do
    {:reply, :ok, do_update(state)}
  end

  def handle_call(:work, _from, state) do
    {:reply, :ok, do_work(state)}
  end

  def handle_call(:update_work, _from, state) do
    state =
      %{state | working: true}
      |> do_update()
      |> do_work()

    {:reply, :ok, state}
  end

  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  def handle_info(:sleep, state = %{mode: mode}) do
    if is_integer(mode) do
      percentage = 100 - min(mode, 100)
      Process.sleep(percentage)
    end

    {:noreply, state}
  end

  # Skipping extra headers generated in case two (or more) blocks are found at the same time
  def handle_info({:header, _header}, state) do
    {:noreply, state}
  end

  def handle_info(:work, state) do
    {:noreply, do_work(state)}
  end

  defp do_work(state = %{mode: :disabled}) do
    state
  end

  @samples 1000
  defp do_work(state) do
    state = generate_candidate(state)
    %{creds: creds, candidate: candidate, target: target} = state

    workers =
      case state.mode do
        percentage when is_integer(percentage) -> max(1, ceil(percentage / 100))
        _ -> 1
      end

    Stats.incr(:hashrate, @samples * workers)

    worker = self()
    header = candidate.header

    tasks =
      Enum.map(1..workers, fn _ ->
        spawn_monitor(fn ->
          %{
            header
            | nonce:
                :rand.uniform(
                  26_959_946_667_150_639_794_667_015_087_019_630_673_637_144_422_540_572_481_103_610_249_215
                )
          }
          |> mine(target, creds, worker)
        end)
      end)

    block =
      receive do
        {:header, header} ->
          block = %{candidate | header: header}

          for {pid, ref} <- tasks do
            send(pid, :stop)
            Process.demonitor(ref, [:flush])

            receive do
              {:DOWN, ^pid, :process, _ref, reason} ->
                Logger.error("Worker died: #{inspect(reason)}")
                nil

              {:min, ^pid, min} ->
                min
            end
          end

          :io.format("Block found: ~p~n", [Block.number(block)])
          block
      after
        2000 ->
          min =
            Enum.map(tasks, fn
              {pid, ref} ->
                send(pid, :stop)
                Process.demonitor(ref, [:flush])

                receive do
                  {:DOWN, ^pid, :process, _ref, reason} ->
                    Logger.error("Worker died: #{inspect(reason)}")
                    nil

                  {:min, ^pid, min} ->
                    min
                end
            end)
            |> Enum.filter(&is_integer/1)
            |> Enum.min()

          if Diode.worker_log?() do
            "target: #{byte_size(Integer.to_string(target))} min: #{byte_size(Integer.to_string(min))} hashrate: #{hashrate()}"
            |> IO.puts()
          end

          nil
      end

    block = block || candidate
    hash = Block.hash(block) |> Hash.integer()
    state = %{state | working: false, candidate: block}

    if hash < target do
      case Block.validate(block, false) do
        <<block_hash::binary-size(32)>> ->
          case Chain.add_block(block_hash) do
            :added ->
              do_update(state)

            other ->
              :io.format("Self generated block is valid but is not accepted: ~p~n", [other])
              %{state | candidate: nil, parent_hash: nil}
          end

        error ->
          :io.format("Self generated block is invalid: ~p~n", [error])
          %{state | candidate: nil, parent_hash: nil}
      end
    else
      state
    end
    |> activate_timer()
  end

  defp mine(header, target, creds, receiver, count \\ 1, min \\ nil) do
    header = update_header(header, creds, 1)
    header2 = update_header(header, creds, 1)
    min2 = min(Hash.integer(header.block_hash), Hash.integer(header2.block_hash))
    min = if min == nil, do: min2, else: min(min, min2)

    cond do
      Hash.integer(header.block_hash) < target ->
        Stats.incr(:hashrate, count)
        send(receiver, {:header, header})
        send(receiver, {:min, self(), min})

      Hash.integer(header2.block_hash) < target ->
        Stats.incr(:hashrate, count)
        send(receiver, {:header, header2})
        send(receiver, {:min, self(), min})

      true ->
        if count >= 100 do
          Stats.incr(:hashrate, count)

          receive do
            :stop ->
              Stats.incr(:hashrate, count)
              send(receiver, {:min, self(), min})
          after
            0 ->
              mine(header2, target, creds, receiver, 2, min)
          end
        else
          mine(header2, target, creds, receiver, count + 2, min)
        end
    end
  end

  defp generate_candidate(state = %Worker{}) do
    state =
      %Worker{candidate: block, creds: creds, proposal: txs} =
      if parent_hash(state) == nil do
        update_parent(state)
      else
        state
      end

    now = System.os_time(:second)

    if block != nil and abs(now - Block.timestamp(block)) < 10 do
      state
    else
      prev_hash = parent_hash(state)
      block = build_block(prev_hash, txs, creds, now)
      target = Block.hash_target(block)

      %Worker{
        state
        | candidate: block,
          target: target,
          proposal: Chain.Pool.proposal()
      }
    end
  end

  def build_block(parent_ref, txs, creds, timestamp \\ System.os_time(:second)) do
    miner = Wallet.address!(creds)

    block =
      BlockProcess.with_block(parent_ref, fn parent ->
        Block.create_empty(parent, creds, timestamp)
      end)

    position = ChainDefinition.block_reward_position(Block.number(block))

    {:ok, block} =
      if position == :first do
        tx =
          %Transaction{
            nonce: Chain.State.ensure_account(Block.state(block), miner) |> Chain.Account.nonce(),
            gasPrice: 0,
            gasLimit: 1_000_000_000,
            to: Diode.registry_address(),
            data: ABI.encode_spec("blockReward"),
            chain_id: Diode.chain_id()
          }
          |> Transaction.sign(Wallet.privkey!(creds))

        Block.append_transaction(block, tx)
      else
        {:ok, block}
      end

    block =
      Enum.reduce(txs, block, fn tx, block ->
        # tx = patch_tx_nonce(block, tx, creds)

        case Block.append_transaction(block, tx) do
          {:error, :wrong_nonce} ->
            Chain.Pool.remove_transaction(Transaction.hash(tx))
            block

          {:error, _other} ->
            block

          {:ok, block} ->
            block
        end
      end)

    {:ok, block} =
      if position == :last do
        used = Block.gas_used(block)
        fees = Block.gas_fees(block)

        tx2 =
          %Transaction{
            nonce: Chain.State.ensure_account(Block.state(block), miner) |> Chain.Account.nonce(),
            gasPrice: 0,
            gasLimit: 1_000_000_000,
            to: Diode.registry_address(),
            data: ABI.encode_call("blockReward", ["uint256", "uint256"], [used, fees]),
            chain_id: Diode.chain_id()
          }
          |> Transaction.sign(Wallet.privkey!(creds))

        Block.append_transaction(block, tx2)
      else
        {:ok, block}
      end

    Block.finalize_header(block)
    |> update_block(creds)
  end

  defp update_block(block, creds, n \\ 1) do
    %{block | header: update_header(block.header, creds, n)}
  end

  defp update_header(header = %{nonce: nonce}, creds, n) do
    %{header | nonce: nonce + n}
    |> Chain.Header.sign(creds)
    |> Chain.Header.update_hash()
  end

  defp activate_timer(state = %{working: true}) do
    state
  end

  defp activate_timer(state) do
    cond do
      state.mode == :poll and (state.proposal == [] or state.proposal == nil) ->
        state

      state.mode == :disabled ->
        state

      true ->
        send(self(), :work)
        %{state | working: true}
    end
  end
end
