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
      Process.flag(:priority, :high)

      block =
        Stats.tc(:sql_block_by_hash, fn ->
          Model.ChainSql.block_by_hash(hash)
        end)

      # IO.puts("block: #{Block.number(block)}")

      %Worker{hash: hash, timeout: 100_000}
      |> do_init(block)
      |> work()
    end

    def init(%Block{} = block) do
      state =
        %Worker{hash: Block.hash(block), timeout: 600_000}
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
          Logger.warning("Long running block process #{secs}s: #{dump}")
          watch(me, secs)
      end
    end

    defp work(state = %Worker{hash: hash, timeout: _timeout}) do
      receive do
        # IO.puts("stopped worker #{Block.number(block)}")
        {:do_work, _block_hash, fun, from = {pid, _tag}} ->
          block = block()

          if Process.alive?(pid) do
            Process.link(pid)

            ret =
              try do
                me = self()
                watcher = spawn_link(fn -> watch(me) end)

                ret = :timer.tc(fn -> fun.(block) end)
                send(watcher, :stop)
                {:ok, ret}
              rescue
                e -> {:error, e, __STACKTRACE__}
              end

            GenServer.reply(from, ret)
            Process.unlink(pid)
          end

          if block != nil do
            GenServer.cast(
              BlockProcess,
              {:i_am_ready, hash, Process.info(self(), :total_heap_size), self()}
            )

            work(state)
          end

        :stop ->
          # IO.puts("stopping block: #{Block.number(block)}")
          :ok
      end
    end
  end

  use GenServer
  defstruct [:ready, :busy, :waiting, :queue, :queue_limit, :req]

  @queue_limit_max 300
  def start_link() do
    GenServer.start_link(
      __MODULE__,
      %BlockProcess{
        ready: %{},
        queue: :queue.new(),
        waiting: :queue.new(),
        busy: MapSet.new(),
        queue_limit: @queue_limit_max,
        req: 0
      },
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:with_worker, block_hash, fun},
        from,
        state = %BlockProcess{waiting: waiting, queue: queue, queue_limit: queue_limit, req: req}
      ) do
    state = %BlockProcess{state | req: req + 1}

    if div(req, 100) == 0 and :queue.len(waiting) > 2 * max_busy(state) do
      Debouncer.immediate({__MODULE__, :queue_full}, fn ->
        Logger.warning(
          "BlockProcess queue is full: #{:queue.len(waiting)}/#{max_busy(state)} queue: #{:queue.len(queue)}/#{queue_limit}"
        )
      end)
    end

    # Giving the Chain process high priority treatment
    {pid, _tag} = from

    state =
      if pid in [Process.whereis(TicketStore), Process.whereis(Chain)] do
        %BlockProcess{state | waiting: :queue.in_r({from, fun, block_hash}, waiting)}
      else
        %BlockProcess{state | waiting: :queue.in({from, fun, block_hash}, waiting)}
      end

    {:noreply, pop_waiting(state)}
  end

  @impl true
  def handle_cast(
        {:add_worker, block_pid, block_hash},
        state = %BlockProcess{}
      ) do
    Process.monitor(block_pid)
    {:noreply, set_worker_mode(state, block_pid, block_hash, :ready)}
  end

  def handle_cast({:i_am_ready, block_hash, {:total_heap_size, size}, pid}, state) do
    {:noreply,
     update_queue_size(state, size * get_os_wordsize())
     |> set_worker_mode(pid, block_hash, :ready)
     |> pop_waiting()}
  end

  def handle_cast({:i_am_ready, block_hash, nil, pid}, state) do
    {:noreply,
     state
     |> set_worker_mode(pid, block_hash, :ready)
     |> pop_waiting()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, remove_pid, reason}, state) do
    if reason != :normal do
      Logger.warning("block_proxy #{inspect(remove_pid)} crashed for #{inspect(reason)}")
    end

    state = set_worker_mode(state, remove_pid, :unknown, :gone)
    {:noreply, pop_waiting(state)}
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

  def with_block(block_ref, fun, timeout \\ 12_000)

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
      {:ok, {time, ret}} ->
        if time > 1_000_000 do
          Logger.warning(
            "BlockProcess took #{div(time, 1000)}ms for #{inspect(Profiler.stacktrace())}"
          )
        end

        ret

      {:error, error, trace} ->
        Kernel.reraise(error, trace)
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
        state = %BlockProcess{busy: busy, ready: ready, queue: queue},
        pid,
        block_hash,
        mode
      ) do
    case mode do
      :busy ->
        busy = MapSet.put(busy, pid)
        ready = map_delete_value(ready, block_hash, pid)
        queue = queue_delete(queue, pid)
        %BlockProcess{state | ready: ready, queue: queue, busy: busy}

      :ready ->
        ready = map_add_value(ready, block_hash, pid)
        busy = MapSet.delete(busy, pid)
        queue_add(%BlockProcess{state | ready: ready, busy: busy}, pid, block_hash)

      :gone ->
        ready =
          Enum.map(ready, fn {hash, pids} -> {hash, List.delete(pids, pid)} end) |> Map.new()

        busy = MapSet.delete(busy, pid)
        queue = queue_delete(queue, pid)

        %BlockProcess{state | ready: ready, queue: queue, busy: busy}
    end
  end

  def max_busy(%BlockProcess{queue_limit: queue_limit}) do
    min(queue_limit - 1, System.schedulers_online() * 2)
  end

  def pop_waiting(oldstate = %BlockProcess{waiting: waiting, ready: ready, busy: busy}) do
    with true <- MapSet.size(busy) < max_busy(oldstate),
         {{:value, {from, fun, block_hash}}, waiting} <- :queue.out(waiting) do
      state = %BlockProcess{oldstate | waiting: waiting}

      case map_get(ready, block_hash) do
        [] ->
          assign_new_worker(state, block_hash, fun, from)

        [pid | _rest] ->
          send(pid, {:do_work, block_hash, fun, from})
          set_worker_mode(state, pid, block_hash, :busy)
      end
    else
      _ ->
        oldstate
    end
  end

  def assign_new_worker(state, block_hash, fun, from) do
    {pid, _mon} = spawn_monitor(fn -> Worker.init(block_hash) end)
    send(pid, {:do_work, block_hash, fun, from})
    set_worker_mode(state, pid, block_hash, :busy)
  end

  defp get_os_wordsize() do
    case :persistent_term.get(:os_wordsize, nil) do
      nil ->
        wordsize = :memsup.get_os_wordsize()
        :persistent_term.put(:os_wordsize, wordsize)
        wordsize

      wordsize ->
        wordsize
    end
  end
end
