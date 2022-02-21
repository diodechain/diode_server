defmodule BlockProcess do
  alias Chain.Block
  require Logger

  @moduledoc """
    Warpper around a Blocks Chain state to avoid copying the data from process to process. At the current
    block size of 44mb on average copying the full merkleized tree takes ~50ms. Sending a message to the BlockProcess
    instead just takes a couple of micros.
  """

  defmodule Worker do
    defstruct [:hash, :block, :timeout]

    def init(hash) when is_binary(hash) do
      block =
        Stats.tc(:sql_block_by_hash, fn ->
          Model.ChainSql.block_by_hash(hash)
        end)

      %Worker{hash: hash, block: block, timeout: 10_000}
      |> do_init()
      |> work()
    end

    def init(%Block{} = block) do
      state =
        %Worker{hash: Block.hash(block), block: block, timeout: 60_000}
        |> do_init()

      Chain.Block.state_tree(block)
      work(state)
    end

    defp do_init(state = %Worker{hash: hash, block: block}) do
      Process.put(__MODULE__, hash)

      if block == nil do
        Logger.debug("empty block #{Base16.encode(hash)} from #{inspect(Profiler.stacktrace())}")
      end

      state
    end

    def is_worker(hash) when is_binary(hash) do
      Process.get(__MODULE__, nil) == hash
    end

    defp work(state = %Worker{hash: hash, block: block, timeout: timeout}) do
      receive do
        # IO.puts("stopped worker #{Block.number(block)}")
        {:with_block, _block_num, fun, pid} ->
          ret =
            try do
              {:ok, fun.(block)}
            rescue
              e -> {:error, e, __STACKTRACE__}
            end

          send(pid, {fun, ret})

          if block != nil do
            GenServer.cast(BlockProcess, {:i_am_ready, hash, self()})
            work(state)
          end
      after
        timeout ->
          if not GenServer.call(BlockProcess, {:can_i_stop?, hash, self()}) do
            work(state)
          end
      end
    end
  end

  use GenServer
  defstruct [:ready, :mons]

  def start_link() do
    GenServer.start_link(__MODULE__, %BlockProcess{ready: %{}, mons: %{}}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:get_proxy, block_hash},
        _from,
        state = %BlockProcess{ready: ready, mons: mons}
      ) do
    case Map.get(ready, block_hash, []) do
      [] ->
        {pid, mon} = spawn_monitor(fn -> Worker.init(block_hash) end)
        {:reply, pid, %BlockProcess{state | mons: Map.put(mons, mon, block_hash)}}

      [pid | rest] ->
        ready = Map.put(ready, block_hash, rest)
        {:reply, pid, %BlockProcess{state | ready: ready}}
    end
  end

  def handle_call(
        {:add_proxy, block_pid, block_hash},
        _from,
        state = %BlockProcess{mons: mons, ready: ready}
      ) do
    mon = Process.monitor(block_pid)
    ready = Map.put(ready, block_hash, [block_pid | Map.get(ready, block_hash, [])])
    {:reply, block_pid, %BlockProcess{state | mons: Map.put(mons, mon, block_hash), ready: ready}}
  end

  def handle_call({:can_i_stop?, block_hash, pid}, _from, state = %BlockProcess{ready: ready}) do
    workers = Map.get(ready, block_hash, [])

    if pid in workers do
      rest = List.delete(workers, pid)
      ready = Map.put(ready, block_hash, rest)
      {:reply, true, %BlockProcess{state | ready: ready}}
    else
      {:reply, false, state}
    end
  end

  @impl true
  def handle_cast({:i_am_ready, block_hash, pid}, state = %BlockProcess{ready: ready}) do
    workers = [pid | Map.get(ready, block_hash, [])]
    ready = Map.put(ready, block_hash, workers)
    {:noreply, %BlockProcess{state | ready: ready}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        state = %BlockProcess{ready: ready, mons: mons}
      ) do
    block_hash = Map.get(mons, ref)
    workers = List.delete(Map.get(ready, block_hash, []), pid)
    ready = Map.put(ready, block_hash, workers)
    mons = Map.delete(mons, ref)

    if reason != :normal do
      Logger.warn("block_proxy #{Base16.encode(block_hash)} crashed for #{inspect(reason)}")
    end

    {:noreply, %BlockProcess{state | mons: mons, ready: ready}}
  end

  def fetch(block_ref, methods) when is_list(methods) do
    with_block(block_ref, fn block ->
      Enum.map(methods, fn method -> apply(Block, method, [block]) end)
    end)
  end

  def with_account(block_ref, account_id, fun) do
    with_state(block_ref, fn state -> fun.(Chain.State.account(state, account_id)) end)
  end

  def with_state(block_ref, fun) do
    with_block(block_ref, fn block -> fun.(Block.state(block)) end)
  end

  def with_block(<<block_hash::binary-size(32)>>, fun) do
    GenServer.call(__MODULE__, {:get_proxy, block_hash})
    |> do_with_block(fun)
  end

  def with_block(%Block{} = block, fun), do: fun.(block)
  def with_block("latest", fun), do: with_block(Chain.peak(), fun)
  def with_block("pending", fun), do: Chain.Worker.with_candidate(fun)
  def with_block("earliest", fun), do: with_block(0, fun)
  def with_block(nil, fun), do: fun.(nil)
  def with_block(num, fun) when is_integer(num), do: with_block(Chain.blockhash(num), fun)

  def with_block(<<"0x", _rest::binary()>> = ref, fun),
    do: with_block(Base16.decode_int(ref), fun)

  defp do_with_block(block_pid, fun) when is_pid(block_pid) do
    ref = Process.monitor(block_pid)
    send(block_pid, {:with_block, :pid, fun, self()})

    receive do
      {:DOWN, ^ref, :process, _pid, reason} ->
        raise "failed with_block() for #{inspect(reason)}"

      {^fun, {:ok, ret}} ->
        Process.demonitor(ref, [:flush])
        ret

      {^fun, {:error, error, trace}} ->
        Process.demonitor(ref, [:flush])
        Kernel.reraise(error, trace)
    end
  end

  def start_block(%Block{} = block) do
    pid = spawn(fn -> Worker.init(block) end)
    ^pid = GenServer.call(__MODULE__, {:add_proxy, pid, Block.hash(block)})
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
end
