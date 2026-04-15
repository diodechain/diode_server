# CMerkleTree RSS workloads (plan: workloads A–D).
#
# Usage (from repo root, after `mix compile`):
#   mix run scripts/cmerkle_memory_bench.exs
#   mix run scripts/cmerkle_memory_bench.exs -- --workload all --trees 25 --pairs 800 --samples 3
#
# Workloads A/B/C retain `trees` handles (B/C: one near-duplicate tree per handle). Lower `--trees`
# if the VM RSS is too high. See scripts/cmerkle_memory_evaluation_report.md for results.
#
# CSV columns: workload,iteration,trees,pairs,vm_rss_kb,vm_hwm_kb,node_count,pair_count,approx_bytes,wall_ms

defmodule CMerkleMemoryBench do
  @moduledoc false

  def main(argv \\ []) do
    argv = normalize_argv(argv)

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          workload: :string,
          trees: :integer,
          pairs: :integer,
          samples: :integer,
          csv: :boolean
        ],
        aliases: [w: :workload]
      )

    workload = Keyword.get(opts, :workload, "all")
    # Retained trees (B/C hold one fork per k); lower this if RSS is too high.
    trees_k = Keyword.get(opts, :trees, 25)
    pairs_n = Keyword.get(opts, :pairs, 800)
    samples = Keyword.get(opts, :samples, 2)
    csv = Keyword.get(opts, :csv, true)

    if not csv do
      IO.puts("# struct_sizes: #{inspect(CMerkleTree.struct_sizes())}")
      dbg_malloc()
    end

    workloads =
      case workload do
        "all" -> ~w(a b c d)
        w -> String.split(w, ",", trim: true)
      end

    if csv do
      IO.puts("workload,iteration,trees,pairs,vm_rss_kb,vm_hwm_kb,node_count,pair_count,approx_bytes,wall_ms")
    end

    for w <- workloads, i <- 1..samples do
      run = fn -> run_workload(w, trees_k, pairs_n) end
      {t0, _} = :timer.tc(run)
      {rss, hwm} = read_proc_rss_hwm()
      {nodes, pairs_c, approx} = sample_stats()

      if csv do
        IO.puts(
          "#{w},#{i},#{trees_k},#{pairs_n},#{rss},#{hwm},#{nodes},#{pairs_c},#{approx},#{div(t0, 1000)}"
        )
      else
        IO.inspect({w, i, rss, hwm, nodes, pairs_c, approx, div(t0, 1000)}, label: :sample)
      end
    end

    :ok
  end

  defp dbg_malloc do
    case CMerkleTree.malloc_info() do
      :unsupported -> IO.puts("# malloc_info: unsupported")
      bin when is_binary(bin) -> IO.puts(String.slice(bin, 0, 400))
    end
  end

  defp read_proc_rss_hwm do
    path = "/proc/#{System.pid()}/status"

    case File.read(path) do
      {:ok, body} ->
        rss = parse_kv(body, "VmRSS:")
        hwm = parse_kv(body, "VmHWM:")
        {rss, hwm}

      _ ->
        {0, 0}
    end
  end

  defp parse_kv(body, key) do
    case Regex.run(~r/#{Regex.escape(key)}\s+(\d+)\s+kB/i, body) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp sample_stats do
    case Process.get(:cmerkle_mem_bench_tree) do
      nil -> {0, 0, 0}
      t -> CMerkleTree.memory_stats(t)
    end
  end

  defp test_pairs(n) do
    Enum.map(1..n, fn idx ->
      {String.pad_leading("#{idx}", 32), CMerkleTree.hash("#{idx}")}
    end)
  end

  # A: many clones share one SharedState — minimal duplication.
  defp run_workload("a", trees_k, pairs_n) do
    data = test_pairs(pairs_n)
    base = CMerkleTree.from_list(data) |> CMerkleTree.lock()

    refs =
      for _ <- 1..trees_k do
        CMerkleTree.clone(base)
      end

    Process.put(:cmerkle_mem_bench_tree, hd(refs))
    _ = refs
    :erlang.garbage_collect()
  end

  # B: one locked base, then `trees_k` times clone → insert one leaf (COW full copy per fork). All retained.
  # The base handle is scoped so the original SharedState can be collected once forks have diverged.
  defp run_workload("b", trees_k, pairs_n) do
    data = test_pairs(pairs_n)
    extra = CMerkleTree.hash("extra-leaf")

    forks =
      (fn ->
         base = CMerkleTree.from_list(data) |> CMerkleTree.lock()

         Enum.map(1..trees_k, fn _ ->
           CMerkleTree.clone(base) |> CMerkleTree.insert(extra, extra)
         end)
       end).()

    Process.put(:cmerkle_mem_bench_tree, hd(forks))
    _ = forks
    :erlang.garbage_collect()
  end

  # C: `trees_k` independent trees (same keys, last value varies). All retained — no COW sharing.
  defp run_workload("c", trees_k, pairs_n) do
    data = test_pairs(pairs_n)
    {k, _v} = List.last(data)

    trees =
      Enum.map(1..trees_k, fn i ->
        alt = CMerkleTree.hash("alt#{i}")
        CMerkleTree.from_list(Enum.drop(data, -1) ++ [{k, alt}])
      end)

    Process.put(:cmerkle_mem_bench_tree, hd(trees))
    _ = trees
    :erlang.garbage_collect()
  end

  # D: churn — allocate and drop trees to stress PreAllocator malloc/free stripes.
  defp run_workload("d", trees_k, pairs_n) do
    data = test_pairs(pairs_n)

    last =
      Enum.reduce(1..trees_k, nil, fn _, _acc ->
        t = CMerkleTree.from_list(data)
        _ = CMerkleTree.root_hash(t)
        t
      end)

    Process.put(:cmerkle_mem_bench_tree, last)
    :erlang.garbage_collect()
  end

  defp run_workload(other, _, _) do
    raise ArgumentError, "unknown workload #{inspect(other)}, expected a|b|c|d|all"
  end

  # `mix run scripts/foo.exs -- --trees 5` may pass ["scripts/foo.exs", "--", "--trees", "5"].
  defp normalize_argv(argv) do
    argv
    |> Enum.flat_map(fn
      "--" -> []
      x -> [x]
    end)
    |> Enum.reject(&String.ends_with?(&1, ".exs"))
  end
end

CMerkleMemoryBench.main(System.argv())
