# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Contract tests for docs/specs/change-state-diff-perf.md (Phases A–E).
defmodule StateDiffPerfContractTest do
  use ExUnit.Case, async: false

  alias Chain.{Account, State}

  defp addr(i), do: <<i::unsigned-size(160)>>
  defp slot(i), do: <<i::unsigned-size(256)>>

  defp build_live(n, slots_per) do
    Enum.reduce(1..n, State.new(), fn i, st ->
      storage =
        for s <- 1..slots_per do
          {slot(i * 10_000 + s), <<i * 1000 + s::unsigned-size(256)>>}
        end

      State.set_account(st, addr(i), %Account{
        nonce: i,
        balance: i * 100,
        storage_root: storage,
        code: <<i>>,
        map_backed: false
      })
    end)
    |> State.normalize()
  end

  defp peak_from_compact(n, slots_per) do
    build_live(n, slots_per)
    |> State.lock()
    |> State.compact()
    |> State.uncompact()
    |> State.lock()
  end

  defp bump_nonce(state, id) do
    meta = State.ensure_account(state, id)
    State.set_account(state, id, %{meta | nonce: meta.nonce + 1})
  end

  describe "cached_root_after_uncompact" do
    test "compact→uncompact preserves storage roots used by difference" do
      live = build_live(16, 2) |> State.lock()
      ids = Enum.map(1..16, &addr/1)

      roots_before =
        Map.new(ids, fn id -> {id, CAccountMap.storage_root_hash(live.accounts, id)} end)

      compact = State.compact(live)
      sample = Map.fetch!(compact.accounts, addr(1))
      assert match?(<<_::binary-size(32)>>, sample.root_hash)
      assert sample.root_hash == roots_before[addr(1)]

      restored = State.uncompact(compact) |> State.lock()

      for id <- ids do
        assert CAccountMap.storage_root_hash(restored.accounts, id) == roots_before[id]
      end
    end
  end

  describe "root_invalidated_after_storage_put" do
    test "storage_put_map changes storage root and difference reports it" do
      prev = build_live(12, 2) |> State.lock()
      id = addr(3)
      before = CAccountMap.storage_root_hash(prev.accounts, id)

      next =
        prev
        |> State.clone()
        |> State.storage_put_map(%{id => %{slot(30_001) => <<999::unsigned-size(256)>>}})
        |> State.normalize()

      after_root = CAccountMap.storage_root_hash(next.accounts, id)
      assert after_root != before

      assert Enum.any?(State.difference(prev, next), fn {^id, report} ->
               match?(
                 %{state: state, root_hash: {^before, ^after_root}} when map_size(state) > 0,
                 report
               )
             end)
    end
  end

  describe "cow_unique_after_write" do
    test "clone then write does not change parent storage or state root" do
      peak = peak_from_compact(20, 2)
      parent_hash = State.hash(peak)
      parent_root = CAccountMap.storage_root_hash(peak.accounts, addr(1))
      parent_slot = CAccountMap.storage_get(peak.accounts, addr(1), slot(10_001))

      _fork =
        peak
        |> State.clone()
        |> State.storage_put_map(%{addr(1) => %{slot(10_001) => <<42::unsigned-size(256)>>}})
        |> State.normalize()

      assert State.hash(peak) == parent_hash
      assert CAccountMap.storage_root_hash(peak.accounts, addr(1)) == parent_root
      assert CAccountMap.storage_get(peak.accounts, addr(1), slot(10_001)) == parent_slot
    end
  end

  describe "difference_full tuple shape" do
    # Phase C extends to a 6-tuple with root_a/root_b; assert shipping 4-tuple until then.
    test "difference_full returns addr/sides/storage_diff quads" do
      prev = build_live(10, 2) |> State.lock()

      next =
        prev
        |> State.clone()
        |> State.storage_put_map(%{addr(1) => %{slot(1) => <<1::unsigned-size(256)>>}})
        |> bump_nonce(addr(2))
        |> State.normalize()

      full = CAccountMap.difference_full(prev.accounts, next.accounts)
      assert full != []

      for {addr, side_a, side_b, storage_diff} <- full do
        assert byte_size(addr) == 20
        assert side_a == nil or match?({_n, _b, _c}, side_a)
        assert side_b == nil or match?({_n, _b, _c}, side_b)
        assert is_list(storage_diff)
      end
    end

    test "State.difference report includes root_hash when storage changes" do
      prev = build_live(8, 2) |> State.lock()

      next =
        prev
        |> State.clone()
        |> State.storage_put_map(%{addr(5) => %{slot(50_005) => <<5::unsigned-size(256)>>}})
        |> State.normalize()

      {_addr, report} = Enum.find(State.difference(prev, next), fn {a, _} -> a == addr(5) end)
      assert map_size(report.state) > 0
      assert match?({<<_::binary-size(32)>>, <<_::binary-size(32)>>}, report.root_hash)
    end
  end

  describe "compact_small_delta prepare_state shape" do
    test "few changed accounts on compact-uncompact peak round-trip via difference" do
      changed = 3
      peak = peak_from_compact(40, 2)

      next =
        Enum.reduce(1..changed, State.clone(peak), fn i, acc ->
          id = addr(i)

          acc
          |> State.storage_put_map(%{
            id => %{slot(i * 10_000 + 1) => <<i * 9::unsigned-size(256)>>}
          })
          |> bump_nonce(id)
        end)
        |> State.normalize()

      delta = State.difference(peak, next)
      assert length(delta) == changed

      restored =
        peak
        |> State.clone()
        |> State.apply_difference(delta)
        |> State.normalize()

      assert State.hash(restored) == State.hash(next)
    end
  end
end
