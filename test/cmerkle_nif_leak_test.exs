# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# NIF memory leak regression tests (see scripts/cmerkle_leak_test.exs).
defmodule CMerkleNifLeakTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  @moduletag :cmerkle_leak
  @moduletag timeout: 300_000

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>
  defp val(i), do: <<i + 1::unsigned-size(256)>>

  defp force_gc do
    for _ <- 1..3, do: :erlang.garbage_collect()
  end

  defp rss_kb do
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

  describe "canonical lock dedup must not leak SharedState" do
    test "empty trie lock storm" do
      baseline = rss_kb()

      for _ <- 1..300 do
        CMerkleTree.new() |> CMerkleTree.lock()
      end

      force_gc()
      {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()
      assert orphans == 0
      assert rss_kb() - baseline < 50_000
    end

    test "account_map_lock with identical storage roots" do
      baseline = rss_kb()
      n = 60

      for _ <- 1..30 do
        map =
          Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
            storage =
              CMerkleTree.insert_items(CMerkleTree.new(), [
                {slot(1), val(1)},
                {slot(2), val(2)}
              ])

            CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
          end)

        _ = CAccountMap.lock(map)
      end

      force_gc()
      {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()
      assert orphans == 0
      assert rss_kb() - baseline < 80_000
    end

    test "block sync shaped compact uncompact lock loop" do
      baseline = rss_kb()
      n = 40

      for _ <- 1..25 do
        state =
          Enum.reduce(1..n, State.new(), fn i, st ->
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
      end

      force_gc()
      {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()
      assert orphans == 0
      assert rss_kb() - baseline < 100_000
    end
  end
end
