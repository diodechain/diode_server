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
    test "empty account map lock storm" do
      baseline = rss_kb()

      for _ <- 1..300 do
        CAccountMap.new() |> CAccountMap.lock()
      end

      force_gc()
      {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()
      assert orphans <= 2
      assert rss_kb() - baseline < 50_000
    end

    test "account_map_lock with identical storage roots" do
      baseline = rss_kb()
      n = 60
      storage = [{slot(1), val(1)}, {slot(2), val(2)}]

      for _ <- 1..30 do
        map =
          Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
            CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
          end)

        _ = CAccountMap.lock(map)
      end

      force_gc()
      {_locked, orphans, _shared, _res} = CMerkleTree.nif_stats()
      assert orphans == 0
      assert rss_kb() - baseline < 80_000
    end

    test "locked clone GC retains canonical map until last registration" do
      shared =
        Enum.reduce(1..80, CAccountMap.new(), fn i, acc ->
          storage = [{String.pad_leading("lc#{i}", 32), Diode.hash("lc#{i}")}]
          CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
        end)

      for _ <- 1..300 do
        _ = shared |> CAccountMap.clone() |> CAccountMap.lock()
      end

      force_gc()
      {locked, orphans, shared_count, _res} = CMerkleTree.nif_stats()
      assert orphans == 0
      assert locked <= 80
      assert shared_count < 2000
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
              storage_root: [{slot(i), val(i)}],
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

    test "account_map difference_full loop does not grow shared_states" do
      n = 80
      base = build_diff_map(n)

      fork =
        CAccountMap.clone(base)
        |> then(fn map ->
          map
          |> CAccountMap.storage_put_map(%{
            addr(3) => %{slot(99_999) => <<99_999::unsigned-size(256)>>}
          })
          |> then(fn m ->
            {nonce, balance, _root, code} = CAccountMap.get(m, addr(3))
            CAccountMap.put_meta(m, addr(3), nonce + 1, balance, code)
          end)
        end)

      {_locked0, _orphans0, shared0, _res0} = CMerkleTree.nif_stats()

      for _ <- 1..100 do
        _ = CAccountMap.difference_full(base, fork)
      end

      force_gc()
      {_locked, orphans, shared, _res} = CMerkleTree.nif_stats()
      assert orphans == 0
      assert shared - shared0 < 500
    end
  end

  defp build_diff_map(n) do
    Enum.reduce(1..n, CAccountMap.new(), fn i, acc ->
      storage = [{slot(i), val(i)}]
      CAccountMap.put(acc, addr(i), i, i * 1_000, storage, <<i>>)
    end)
  end
end
