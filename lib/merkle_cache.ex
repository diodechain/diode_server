defmodule MerkleCache do
  use GenServer
  defstruct [:cache]

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %MerkleCache{cache: []}}
  end

  def merkle(tree = {MapMerkleTree, _opts, dict}) do
    if map_size(dict) > 1000 do
      call({:merkle, dict})
    else
      MerkleTree.copy(tree, MerkleTree2)
    end
  end

  def merkle(tree) do
    MerkleTree.copy(tree, MerkleTree2)
  end

  def root_hash(tree = {MapMerkleTree, _opts, dict}) do
    if map_size(dict) > 1000 do
      call({:root_hash, dict})
    else
      merkle(tree) |> MerkleTree.root_hash()
    end
  end

  def root_hash(tree) do
    merkle(tree) |> MerkleTree.root_hash()
  end

  def difference(tree1 = {MapMerkleTree, _opts, map1}, tree2 = {MapMerkleTree, _opts2, map2}) do
    if MerkleTree.size(tree1) > 1000 do
      call({:difference, map1, map2})
    else
      MerkleTree.difference(tree1, tree2)
    end
  end

  def difference(tree1 = {MapMerkleTree, _opts, map1}, tree2) do
    if MerkleTree.size(tree1) > 1000 do
      map2 = MerkleTree.to_list(tree2) |> Map.new()
      call({:difference, map1, map2})
    else
      MerkleTree.difference(tree1, tree2)
    end
  end

  def difference(tree1, tree2) do
    MerkleTree.difference(tree1, tree2)
  end

  @impl true
  def handle_call({:difference, map1, map2}, from, state) do
    {:reply, tree1, state} = handle_call({:merkle, map1}, from, state)
    root_hash = MerkleTree.root_hash(tree1)

    {state, index} =
      Enum.find_index(state.cache, fn %{root_hash: tree_root_hash} ->
        tree_root_hash == root_hash
      end)
      |> case do
        nil ->
          {do_insert_new(state, MerkleTree.to_list(tree1)), 0}

        index ->
          {state, index}
      end

    {diff, state} = do_diff(state, map2, index)
    {:reply, diff, state}
  end

  def handle_call({:root_hash, map}, from, state) do
    {:reply, tree, state} = handle_call({:merkle, map}, from, state)
    {:reply, MerkleTree.root_hash(tree), state}
  end

  def handle_call({:merkle, map}, _from, state = %{cache: cache}) do
    tenPercent = div(map_size(map), 10)
    lower = max(0, map_size(map) - tenPercent)
    upper = map_size(map) + tenPercent

    Enum.find_index(cache, fn %{tree: tree, sample: sample} ->
      if lower < MerkleTree.size(tree) and MerkleTree.size(tree) < upper do
        score =
          Enum.reduce(sample, 0, fn key, score ->
            if MerkleTree.get(tree, key) == Map.get(map, key) do
              score + 1
            else
              score
            end
          end)

        # IO.puts("score: #{score}")
        score * 2 > length(sample)
      end
    end)
    |> case do
      nil ->
        state = %{cache: [%{tree: tree} | _]} = do_insert_new(state, Map.to_list(map))
        {:reply, tree, state}

      index ->
        {diff, state} = do_diff(state, map, index)
        %{tree: tree} = Enum.at(cache, index)

        tree2 =
          Enum.reduce(diff, tree, fn {key, {_a, b}}, tree ->
            if b == nil do
              MerkleTree.delete(tree, key)
            else
              MerkleTree.insert(tree, key, b)
            end
          end)

        {:reply, tree2, state}
    end
  end

  defp do_insert_new(state = %{cache: cache}, items) when is_list(items) do
    tree = MerkleTree2.new() |> MerkleTree.insert_items(items)
    sample = Enum.shuffle(items) |> Enum.take(100) |> Enum.map(&elem(&1, 0))
    selfdiff = %{}

    new = %{
      tree: tree,
      sample: sample,
      diffs: %{:erlang.phash2(selfdiff) => selfdiff},
      root_hash: MerkleTree.root_hash(tree)
    }

    %{state | cache: [new | Enum.take(cache, 10)]}
  end

  defp do_diff(state = %{cache: cache}, map, index) do
    {_time, {_key, diff, state}} =
      :timer.tc(fn ->
        %{tree: tree, diffs: diffs} = Enum.at(cache, index)
        key = :erlang.phash2(map)

        diff =
          Map.get(diffs, key) ||
            MerkleTree.difference(tree, MapMerkleTree.from_map(map))

        cache =
          List.update_at(cache, index, fn item ->
            %{item | diffs: Map.put(diffs, key, diff)}
          end)

        {key, diff, %{state | cache: cache}}
      end)

    # IO.puts("MerkleCache.do_diff: #{div(time, 1000)}ms = #{key} / #{map_size(diff)}")
    {diff, state}
  end

  defp call(cmd) do
    GenServer.call(__MODULE__, cmd, 15_000)
  end
end
