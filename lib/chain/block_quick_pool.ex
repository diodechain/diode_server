defmodule Chain.BlockQuickPool do
  use GenServer

  def block_quick_pool_size() do
    5
  end

  def block_quick_partitions() do
    Enum.map(0..(block_quick_pool_size() - 1), &block_quick_partition/1)
  end

  defp block_quick_partition(n) do
    String.to_atom("blockquick_#{n}")
  end

  def next_partition() do
    n = GenServer.call(__MODULE__, :next_partition)
    Process.whereis(block_quick_partition(n))
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_args) do
    {:ok, 0}
  end

  def handle_call(:next_partition, _from, partition) do
    {:reply, partition, rem(partition + 1, block_quick_pool_size())}
  end
end
