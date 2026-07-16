# CMerkleTree NIF memory leak regression harness.
#
# Run from repo root:
#   mix run --no-start scripts/cmerkle_leak_test.exs -- --rounds 50 --max-delta-kb 81920
#
# Options:
#   --rounds N          iterations per scenario (default: 50)
#   --accounts N        accounts for scenarios B/C (default: 80)
#   --max-delta-kb N    fail if RSS growth after GC exceeds this (default: 81920 = 80 MB)
#   --plateau N         consecutive plateau windows (default: 3)
#   --scenario NAME     run only A|B|C (default: all)
#   --seed N            RNG seed (default: 20260709)
#
# Emits LEAK_OK <scenario> <window> on success. Exit non-zero on RSS regression.

defmodule CMerkleLeakTest do
  @moduledoc false

  alias Chain.{Account, State}

  def main(argv) do
    argv = normalize_argv(argv)

    {opts, _} =
      OptionParser.parse!(argv,
        strict: [
          rounds: :integer,
          accounts: :integer,
          max_delta_kb: :integer,
          plateau: :integer,
          scenario: :string,
          seed: :integer
        ]
      )

    rounds = Keyword.get(opts, :rounds, 50)
    accounts = Keyword.get(opts, :accounts, 80)
    max_delta_kb = Keyword.get(opts, :max_delta_kb, 81_920)
    plateau = Keyword.get(opts, :plateau, 3)
    seed = Keyword.get(opts, :seed, 20_260_709)

    scenarios =
      case Keyword.get(opts, :scenario) do
        nil -> ~w(A B C)
        s -> String.split(s, ",", trim: true) |> Enum.map(&String.upcase/1)
      end

    :rand.seed(:exsss, {seed, seed, seed})

    IO.puts(:stderr, """
    === CMerkleTree leak test ===
    otp=#{System.otp_release()} pid=#{:os.getpid()}
    rounds=#{rounds} accounts=#{accounts} max_delta_kb=#{max_delta_kb} plateau=#{plateau}
    scenarios=#{inspect(scenarios)}
    """)

    warmup_gc()

    for id <- scenarios do
      run_scenario(id, rounds, accounts, max_delta_kb, plateau)
    end

    IO.puts(:stderr, "=== leak test finished cleanly ===")
  end

  defp run_scenario(id, rounds, accounts, max_delta_kb, plateau) do
    baseline = measure_rss()

    {_last, _rising} =
      Enum.reduce(1..plateau, {baseline, 0}, fn window, {last, rising} ->
        run_workload(id, rounds, accounts)
        force_gc()
        {locked, orphans, shared, _res, _lazy, _eager} = CMerkleTree.nif_stats()
        rss = measure_rss()
        delta = rss - baseline

        IO.puts(:stderr,
          "LEAK_SAMPLE #{id} window=#{window} rss_kb=#{rss} delta_kb=#{delta} " <>
            "nif_stats={#{locked},#{orphans},#{shared}}"
        )

        cond do
          orphans > 0 ->
            fail!("scenario #{id}: pending orphans=#{orphans} after GC")

          delta > max_delta_kb ->
            fail!("scenario #{id}: RSS delta #{delta} kb exceeds max #{max_delta_kb} kb")

          rss > last + div(max_delta_kb, 4) ->
            new_rising = rising + 1

            if new_rising >= 2 do
              fail!("scenario #{id}: monotonic RSS growth across windows (#{last} -> #{rss} kb)")
            end

            IO.puts("LEAK_OK #{id} #{window}")
            {rss, new_rising}

          true ->
            IO.puts("LEAK_OK #{id} #{window}")
            {rss, 0}
        end
      end)
  end

  defp run_workload("A", rounds, _accounts) do
    Enum.each(1..rounds, fn _ ->
      CMerkleTree.new() |> CMerkleTree.lock()
    end)
  end

  defp run_workload("B", rounds, accounts) do
    Enum.each(1..rounds, fn _ ->
      map =
        Enum.reduce(1..accounts, CAccountMap.new(), fn i, acc ->
          storage =
            CMerkleTree.insert_items(CMerkleTree.new(), [
              {slot(1), val(1)},
              {slot(2), val(2)}
            ])

          CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
        end)

      _ = CAccountMap.lock(map)
    end)
  end

  defp run_workload("C", rounds, accounts) do
    Enum.each(1..rounds, fn _ ->
      state =
        Enum.reduce(1..accounts, State.new(), fn i, st ->
          acc = %Account{
            nonce: i,
            balance: i * 1_000,
            storage_root:
              CMerkleTree.insert_items(CMerkleTree.new(), [
                {slot(i), val(i)}
              ]),
            code: <<i>>
          }

          State.set_account(st, addr(i), acc)
        end)

      state
      |> State.compact()
      |> State.uncompact()
      |> State.normalize()
      |> Chain.State.lock()
    end)
  end

  defp run_workload(other, _, _) do
    fail!("unknown scenario #{inspect(other)}")
  end

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>
  defp val(i), do: <<i + 1::unsigned-size(256)>>

  defp warmup_gc do
    force_gc()
    _ = CMerkleTree.nif_stats()
  end

  defp force_gc do
    for _ <- 1..3, do: :erlang.garbage_collect()
  end

  defp measure_rss do
    case File.read("/proc/#{System.pid()}/status") do
      {:ok, body} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/i, body) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp fail!(msg) do
    IO.puts(:stderr, "LEAK_FAIL #{msg}")
    System.halt(1)
  end

  defp normalize_argv(argv) do
    case argv do
      ["--" | rest] -> rest
      other -> other
    end
  end
end

CMerkleLeakTest.main(System.argv())
