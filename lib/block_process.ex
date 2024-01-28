defmodule BlockProcess do
  alias Chain.Block
  require Logger

  @moduledoc """
    Warpper around a Blocks Chain state to avoid copying the data from process to process. At the current
    block size of 44mb on average copying the full merkleized tree takes ~50ms. Sending a message to the BlockProcess
    instead just takes a couple of micros.
  """

  defmodule Worker do
    defstruct [:hash, :timeout]

    def init(hash) when is_binary(hash) do
      block =
        Stats.tc(:sql_block_by_hash, fn ->
          Model.ChainSql.block_by_hash(hash)
        end)

      # IO.puts("block: #{Block.number(block)}")

      %Worker{hash: hash, timeout: 10_000}
      |> do_init(block)
      |> work()
    end

    def init(%Block{} = block) do
      state =
        %Worker{hash: Block.hash(block), timeout: 60_000}
        |> do_init(block)

      # Prefetching the (normalized) state tree makes sense for serving all API requests
      # (instead of making the first request suffer the cost of fetching the state tree)
      # But when syncing the state tree doesn't need to be normalized here
      unless Diode.syncing?() do
        Chain.Block.state_tree(block)
      end

      work(state)
    end

    defp do_init(state = %Worker{hash: hash}, block) do
      Process.put(__MODULE__, hash)
      Process.put({__MODULE__, :block, hash}, block)

      if block == nil do
        Logger.debug("empty block #{Base16.encode(hash)}")
      end

      # IO.puts("starting block: #{Block.number(block)}")

      state
    end

    def is_worker(hash) when is_binary(hash) do
      hash() == hash
    end

    def is_worker() do
      hash() != nil
    end

    def hash() do
      Process.get(__MODULE__, nil)
    end

    def block() do
      Process.get({__MODULE__, :block, hash()}, nil)
    end

    def with_block(block_hash, fun) do
      key = {__MODULE__, :block, block_hash}

      # IO.inspect(Profiler.stacktrace())
      case Process.get(key, nil) do
        nil ->
          block =
            Stats.tc(:sql_block_by_hash, fn ->
              Model.ChainSql.block_by_hash(block_hash)
            end)

          Process.put(key, block)
          fun.(block)

        block ->
          fun.(block)
      end
    end

    @tick 30_000
    def watch(me, secs \\ 0) do
      receive do
        :stop -> :ok
      after
        @tick ->
          dump = inspect({me, Profiler.stacktrace(me)})
          secs = secs + div(@tick, 1000)
          Logger.warn("Long running block process #{secs}s: #{dump}")
          watch(me, secs)
      end
    end

    defp work(state = %Worker{hash: hash, timeout: timeout}) do
      receive do
        # IO.puts("stopped worker #{Block.number(block)}")
        {:do_work, _block_hash, fun, from = {pid, _tag}} ->
          Process.link(pid)
          block = block()

          ret =
            try do
              me = self()
              watcher = spawn_link(fn -> watch(me) end)
              ret = fun.(block)
              send(watcher, :stop)
              {:ok, ret}
            rescue
              e -> {:error, e, __STACKTRACE__}
            end

          case block do
            nil ->
              GenServer.reply(from, ret)
              Process.unlink(pid)

            _block ->
              # Order is important we want to ensure the ready signal
              # arrives at the BlockProcess before the next `get_worker` call
              GenServer.cast(
                BlockProcess,
                {:i_am_ready, hash, Process.info(self(), :total_heap_size), self()}
              )

              GenServer.reply(from, ret)
              Process.unlink(pid)
              work(state)
          end

        :stop ->
          # IO.puts("stopping block: #{Block.number(block)}")
          :ok
      after
        timeout ->
          nr = Chain.blocknumber(hash)
          peak = Chain.peak()

          cond do
            # keep the top 10 blocks always online...
            BlockProcess.has_cache() and nr > peak - 10 ->
              work(state)

            not GenServer.call(BlockProcess, {:can_i_stop?, hash, self()}, :infinity) ->
              work(state)

            true ->
              # IO.puts("stopping block: #{Chain.blocknumber(hash)} peak: #{Chain.peak()}")
              :ok
          end
      end
    end
  end

  use GenServer
  defstruct [:ready, :busy, :waiting, :mons, :queue, :queue_limit]

  @queue_limit_max 100
  def start_link() do
    GenServer.start_link(
      __MODULE__,
      %BlockProcess{
        ready: %{},
        mons: %{},
        queue: :queue.new(),
        waiting: %{},
        busy: %{},
        queue_limit: @queue_limit_max
      },
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:with_worker, block_hash, fun}, from, state = %BlockProcess{waiting: waiting}) do
    state = %BlockProcess{state | waiting: map_add_value(waiting, block_hash, {from, fun})}
    {:noreply, pop_waiting(state, block_hash)}
  end

  def handle_call(
        {:can_i_stop?, block_hash, pid},
        from,
        state = %BlockProcess{ready: ready, queue: queue, waiting: waiting}
      ) do
    if pid in map_get(ready, block_hash) do
      if map_get(waiting, block_hash) == [] do
        queue = queue_delete(queue, pid)
        ready = map_delete_value(ready, block_hash, pid)
        {:reply, true, %BlockProcess{state | ready: ready, queue: queue}}
      else
        GenServer.reply(from, false)
        {:noreply, set_worker_mode(state, pid, block_hash, :ready) |> pop_waiting(block_hash)}
      end
    else
      {:reply, false, state}
    end
  end

  @impl true
  def handle_cast(
        {:add_worker, block_pid, block_hash},
        state = %BlockProcess{mons: mons}
      ) do
    state =
      %BlockProcess{state | mons: Map.put(mons, Process.monitor(block_pid), block_hash)}
      |> set_worker_mode(block_pid, block_hash, :ready)

    {:noreply, state}
  end

  def handle_cast({:i_am_ready, block_hash, {:total_heap_size, size}, pid}, state) do
    {:noreply,
     update_queue_size(state, size * :memsup.get_os_wordsize())
     |> set_worker_mode(pid, block_hash, :ready)
     |> pop_waiting(block_hash)}
  end

  def handle_cast({:i_am_ready, block_hash, nil, pid}, state) do
    {:noreply,
     state
     |> set_worker_mode(pid, block_hash, :ready)
     |> pop_waiting(block_hash)}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, remove_pid, reason},
        state = %BlockProcess{mons: mons}
      ) do
    remove_hash = Map.get(mons, ref)
    mons = Map.delete(mons, ref)

    state =
      %BlockProcess{state | mons: mons}
      |> set_worker_mode(remove_pid, remove_hash, :gone)

    if reason != :normal do
      Logger.warning("block_proxy #{Base16.encode(remove_hash)} crashed for #{inspect(reason)}")
    end

    {:noreply, pop_waiting(state, remove_hash)}
  end

  defp update_queue_size(
         state = %BlockProcess{queue: queue, queue_limit: prev_queue_limit},
         process_size
       ) do
    with free when free != nil <- :memsup.get_system_memory_data()[:free_memory] do
      used = :queue.len(queue) * process_size
      available = trunc((used + free) * 0.8)
      # find the new target queue limit
      queue_limit = min(@queue_limit_max, max(5, div(available, process_size))) - prev_queue_limit
      # adjust in steps of 1, since `process_size` is not an average
      queue_limit = prev_queue_limit + div(queue_limit, max(1, abs(queue_limit)))
      %BlockProcess{state | queue_limit: queue_limit}
    else
      _ -> state
    end
  end

  defp queue_add(state = %BlockProcess{queue: queue}, pid, hash) do
    if :queue.member({pid, hash}, queue) do
      state
    else
      do_queue_add(state, pid, hash)
    end
  end

  defp do_queue_add(
         state = %BlockProcess{queue: queue, ready: ready, queue_limit: queue_limit},
         pid,
         hash
       ) do
    if :queue.len(queue) > queue_limit do
      {{:value, {remove_pid, remove_hash}}, queue} = :queue.out_r(queue)
      send(remove_pid, :stop)
      ready = map_delete_value(ready, remove_hash, remove_pid)
      %BlockProcess{state | ready: ready, queue: :queue.in_r({pid, hash}, queue)}
    else
      %BlockProcess{state | queue: :queue.in_r({pid, hash}, queue)}
    end
  end

  defp queue_delete(queue, pid) do
    :queue.delete_with(fn {tpid, _} -> tpid == pid end, queue)
  end

  defp map_put(map, key, []), do: Map.delete(map, key)
  defp map_put(map, key, value), do: Map.put(map, key, value)
  defp map_get(map, key), do: Map.get(map, key, [])

  defp map_delete_value(map, key, value) do
    map_put(map, key, List.delete(map_get(map, key), value))
  end

  defp map_add_value(map, key, value) do
    Map.update(map, key, [value], fn rest ->
      if Enum.member?(rest, value) do
        rest
      else
        rest ++ [value]
      end
    end)
  end

  def fetch(block_ref, methods) when is_list(methods) do
    with_block(block_ref, fn block ->
      Enum.map(methods, fn method -> apply(Block, method, [block]) end)
    end)
  end

  def with_account_tree(block_ref, account_id, fun) do
    with_block(block_ref, fn block -> fun.(Block.account_tree(block, account_id)) end)
  end

  def with_account(block_ref, account_id, fun) do
    with_state(block_ref, fn state -> fun.(Chain.State.account(state, account_id)) end)
  end

  def with_state(block_ref, fun) do
    with_block(block_ref, fn block -> fun.(Block.state(block)) end)
  end

  def with_block(block_ref, fun, timeout \\ 120_000)

  def with_block(<<block_hash::binary-size(32)>>, fun, timeout) do
    cond do
      not Chain.block_by_hash?(block_hash) ->
        with_block(nil, fun, timeout)

      not Worker.is_worker() ->
        do_with_worker(block_hash, fun, timeout)

      Worker.hash() == block_hash ->
        fun.(Worker.block())

      true ->
        Stats.tc(:sql_block_by_hash, fn ->
          Model.ChainSql.block_by_hash(block_hash)
        end)
        |> with_block(fun, timeout)
    end
  end

  def with_block(%Block{} = block, fun, _timeout), do: fun.(block)
  def with_block("latest", fun, timeout), do: with_block(Chain.peak(), fun, timeout)
  def with_block("pending", fun, _timeout), do: Chain.Worker.with_candidate(fun)
  def with_block("earliest", fun, timeout), do: with_block(0, fun, timeout)
  def with_block(nil, fun, _timeout), do: fun.(nil)

  def with_block(num, fun, timeout) when is_integer(num),
    do: with_block(Chain.blockhash(num), fun, timeout)

  def with_block(<<"0x", _rest::binary>> = ref, fun, timeout) do
    if byte_size(ref) >= 66 do
      # assuming it's a block hash
      with_block(Base16.decode(ref), fun, timeout)
    else
      # assuming it's a block index
      with_block(Base16.decode_int(ref), fun, timeout)
    end
  end

  defp do_with_worker(block_hash, fun, timeout) do
    case GenServer.call(__MODULE__, {:with_worker, block_hash, fun}, timeout) do
      {:ok, ret} -> ret
      {:error, error, trace} -> Kernel.reraise(error, trace)
    end
  end

  def start_block(%Block{} = block) do
    pid = spawn(fn -> Worker.init(block) end)
    GenServer.cast(__MODULE__, {:add_worker, pid, Block.hash(block)})
    Block.hash(block)
  end

  def maybe_cache(hash, key, fun) do
    if Worker.is_worker(hash) do
      case Process.get({Worker, key}, nil) do
        nil ->
          value = fun.()
          Process.put({Worker, key}, value)
          value

        value ->
          value
      end
    else
      fun.()
    end
  end

  def has_cache() do
    [:state] in Process.get_keys()
  end

  def set_worker_mode(
        state = %BlockProcess{busy: busy, ready: ready, queue: queue, mons: mons},
        pid,
        block_hash,
        mode
      ) do
    case mode do
      :busy ->
        busy = map_add_value(busy, block_hash, pid)
        ready = map_delete_value(ready, block_hash, pid)
        queue = queue_delete(queue, pid)
        %BlockProcess{state | ready: ready, queue: queue, busy: busy}

      :ready ->
        ready = map_add_value(ready, block_hash, pid)
        busy = map_delete_value(busy, block_hash, pid)
        queue_add(%BlockProcess{state | ready: ready, busy: busy}, pid, block_hash)

      :gone ->
        ready = map_delete_value(ready, block_hash, pid)
        busy = map_delete_value(busy, block_hash, pid)
        queue = queue_delete(queue, pid)

        %BlockProcess{state | ready: ready, queue: queue, busy: busy, mons: mons}
    end
  end

  def pop_waiting(
        oldstate = %BlockProcess{waiting: waiting, ready: ready, busy: busy},
        block_hash
      ) do
    with [{from, fun} | block_waits] <- map_get(waiting, block_hash) do
      state = %BlockProcess{oldstate | waiting: map_put(waiting, block_hash, block_waits)}

      case {map_get(ready, block_hash), map_get(busy, block_hash)} do
        {[], []} ->
          assign_new_worker(state, block_hash, fun, from)

        {[], busy_blocks} ->
          if length(block_waits) > length(busy_blocks) do
            assign_new_worker(state, block_hash, fun, from)
          else
            oldstate
          end

        {[pid | _rest], _} ->
          send(pid, {:do_work, block_hash, fun, from})
          set_worker_mode(state, pid, block_hash, :busy)
      end
    else
      _ -> oldstate
    end
  end

  def assign_new_worker(state = %BlockProcess{mons: mons}, block_hash, fun, from) do
    {pid, mon} = spawn_monitor(fn -> Worker.init(block_hash) end)
    send(pid, {:do_work, block_hash, fun, from})

    %BlockProcess{state | mons: Map.put(mons, mon, block_hash)}
    |> set_worker_mode(pid, block_hash, :busy)
  end
end
