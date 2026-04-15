# CMerkleTree NIF stress / fuzz harness.
# Run from repo root: mix run scripts/cmerkle_fuzz.exs -- [options]
#
# Options:
#   --iterations N   number of fuzz rounds (default: 0 = run until SIGINT)
#   --seed N         RNG seed for reproducibility (default: random)
#   --max-keys N     cap keys per tree per scenario (default: 900)
#
# Each successful round prints: FUZZ_OK <round> <scenario>
# On Elixir exception, prints stack trace then exits non-zero.
# Native crashes (segfault/abort) are not caught here; use scripts/cmerkle_fuzz.sh for a log file.

defmodule CMerkleFuzz do
  @moduledoc false

  def main(argv) do
    {opts, _} =
      OptionParser.parse!(argv,
        strict: [
          iterations: :integer,
          seed: :integer,
          max_keys: :integer
        ]
      )

    iterations = Keyword.get(opts, :iterations, 0)
    max_keys = Keyword.get(opts, :max_keys, 900) |> max(16)

    seed =
      case Keyword.get(opts, :seed) do
        nil -> :rand.uniform(1_000_000_000)
        s -> s
      end

    :rand.seed(:exsss, {seed, seed, seed})

    IO.puts(:stderr, """
    === CMerkleTree fuzz ===
    #{runtime_banner()}
    seed=#{seed} iterations=#{iterations |> format_iters()} max_keys=#{max_keys}
    """)

    ctx = %{max_keys: max_keys, seed: seed}

    if iterations <= 0 do
      Stream.iterate(1, &(&1 + 1))
      |> Enum.each(fn round ->
        run_round(round, ctx)
      end)
    else
      Enum.each(1..iterations, fn round ->
        run_round(round, ctx)
      end)
    end

    IO.puts(:stderr, "=== fuzz finished cleanly ===")
  end

  defp format_iters(0), do: "infinite (SIGINT to stop)"
  defp format_iters(n), do: Integer.to_string(n)

  defp runtime_banner do
    "otp=#{System.otp_release()} elixir=#{System.version()} pid=#{:os.getpid()}"
  end

  defp run_round(round, ctx) do
    scenario = :rand.uniform(7)

    case scenario do
      1 -> s_string_batch_insert_diff(round, ctx)
      2 -> s_u256_sequential_diff(round, ctx)
      3 -> s_clone_parallel_extensions_diff(round, ctx)
      4 -> s_clone_overwrite_diff(round, ctx)
      5 -> s_triple_fork_diff(round, ctx)
      6 -> s_delete_and_reinsert(round, ctx)
      7 -> s_proofs_and_roots(round, ctx)
    end

    if rem(round, 50) == 0 do
      :erlang.garbage_collect()
    end

    IO.puts("FUZZ_OK #{round} #{scenario}")
  end

  defp s_string_batch_insert_diff(_round, %{max_keys: mk}) do
    n = :rand.uniform(div(mk, 2)) + 40
    data = Enum.map(1..n, fn i -> {String.pad_leading("#{i}", 32), CMerkleTree.hash("f#{i}")} end)
    {a, rest} = Enum.split(data, div(n * 3, 5))
    {b, c} = Enum.split(rest, div(length(rest), 2) |> max(1))

    base = CMerkleTree.new() |> CMerkleTree.insert_items(a)

    t2 =
      base |> CMerkleTree.clone() |> CMerkleTree.insert_items(b ++ c)

    t_alt =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(b)
      |> CMerkleTree.insert_items(Enum.take(c, min(length(c), 50)))

    _ = CMerkleTree.difference(t2, t_alt)
    _ = CMerkleTree.root_hash(t2)
    _ = CMerkleTree.root_hash(t_alt)
  end

  defp s_u256_sequential_diff(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(mk, 520)) + 80

    slots =
      Enum.map(0..hi, fn i ->
        {<<i::unsigned-size(256)>>, <<(i * 7 + 1)::unsigned-size(256)>>}
      end)

    base = CMerkleTree.new() |> CMerkleTree.insert_items(slots)

    left =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map((hi + 1)..(hi + 40), fn i ->
          {<<i::unsigned-size(256)>>, <<(i * 3)::unsigned-size(256)>>}
        end)
      )

    right =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map((hi + 41)..(hi + 95), fn i ->
          {<<i::unsigned-size(256)>>, <<(i * 13)::unsigned-size(256)>>}
        end)
      )

    _ = CMerkleTree.difference(left, right)
    _ = CMerkleTree.root_hash(left)
    _ = CMerkleTree.root_hash(right)
  end

  defp s_clone_parallel_extensions_diff(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(mk, 400)) + 50

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(0..hi, fn i -> {<<i::unsigned-size(256)>>, <<(i * 11)::unsigned-size(256)>>} end)
      )

    ext1 = (hi + 1)..(hi + 30)
    ext2 = (hi + 31)..(hi + 70)

    left =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(Enum.map(ext1, fn i -> {<<i::unsigned-size(256)>>, <<i::unsigned-size(256)>>} end))

    right =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(Enum.map(ext2, fn i -> {<<i::unsigned-size(256)>>, <<(i + 9)::unsigned-size(256)>>} end))

    _ = CMerkleTree.difference(left, right)
  end

  defp s_clone_overwrite_diff(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(mk, 350)) + 80

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(0..hi, fn i -> {<<i::unsigned-size(256)>>, <<(i * 5)::unsigned-size(256)>>} end)
      )

    left =
      base
      |> CMerkleTree.clone()
      |> CMerkleTree.insert_items(
        Enum.map((hi + 1)..(hi + 35), fn i -> {<<i::unsigned-size(256)>>, <<(i * 2)::unsigned-size(256)>>} end)
      )

    lo = div(hi, 4)
    mid = lo + :rand.uniform(max(div(hi - lo, 2), 5))

    right =
      base
      |> CMerkleTree.clone()
      |> then(fn t ->
        Enum.reduce(lo..mid, t, fn i, acc ->
          CMerkleTree.insert(acc, <<i::unsigned-size(256)>>, <<(i * 17)::unsigned-size(256)>>)
        end)
      end)

    _ = CMerkleTree.difference(left, right)
  end

  defp s_triple_fork_diff(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 280)) + 60

    base =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(1..n, fn i -> {String.pad_leading("#{i}", 32), CMerkleTree.hash("b#{i}")} end)
      )

    a = base |> CMerkleTree.clone() |> CMerkleTree.insert(String.pad_leading("x", 32), CMerkleTree.hash("x"))
    b = base |> CMerkleTree.clone() |> CMerkleTree.insert(String.pad_leading("y", 32), CMerkleTree.hash("y"))
    c = base |> CMerkleTree.clone() |> CMerkleTree.insert(String.pad_leading("z", 32), CMerkleTree.hash("z"))

    _ = CMerkleTree.difference(a, b)
    _ = CMerkleTree.difference(b, c)
    _ = CMerkleTree.difference(a, c)
  end

  defp s_delete_and_reinsert(_round, %{max_keys: mk}) do
    n = :rand.uniform(min(mk, 200)) + 30
    keys = Enum.map(1..n, fn i -> String.pad_leading("#{i}", 32) end)

    t =
      Enum.reduce(keys, CMerkleTree.new(), fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash(k))
      end)

    to_del = Enum.take_random(keys, div(length(keys), 3) |> max(3))

    t =
      Enum.reduce(to_del, t, fn k, acc ->
        CMerkleTree.delete(acc, k)
      end)

    t =
      Enum.reduce(to_del, t, fn k, acc ->
        CMerkleTree.insert(acc, k, CMerkleTree.hash("re#{k}"))
      end)

    _ = CMerkleTree.root_hash(t)
    _ = CMerkleTree.size(t)
  end

  defp s_proofs_and_roots(_round, %{max_keys: mk}) do
    hi = :rand.uniform(min(180, mk)) + 20

    t =
      CMerkleTree.new()
      |> CMerkleTree.insert_items(
        Enum.map(0..hi, fn i -> {<<i::unsigned-size(256)>>, <<(i * 3)::unsigned-size(256)>>} end)
      )

    _ = CMerkleTree.root_hash(t)
    _ = CMerkleTree.root_hashes(t)
    k = <<(:rand.uniform(hi))::unsigned-size(256)>>
    _ = CMerkleTree.get_proofs(t, k)
  end
end

try do
  CMerkleFuzz.main(System.argv())
rescue
  e ->
    IO.puts(:stderr, Exception.format(:error, e, __STACKTRACE__))
    IO.puts(:stderr, "FUZZ_ABORT elixir_exception")
    System.halt(1)
end
