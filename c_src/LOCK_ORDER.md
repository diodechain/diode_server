# CMerkleTree NIF — lock order and deadlock scenario registry

This document inventories mutex layers in [`nif.cpp`](nif.cpp), documents acquisition order, and maps every known deadlock / liveness scenario to regression tests.

See also [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) (F-5 fix) and [`scripts/cmerkle_parallel_stress.exs`](../scripts/cmerkle_parallel_stress.exs).

## Mutex layers

| Mutex | Type | Scope | Used by |
|-------|------|-------|---------|
| `LockedStates::mtx` | `ErlNifMutex` | Global | `enter_lock`, `leave_lock`, `destruct_merkletree_type` |
| `SharedState::mtx` | `ErlNifMutex` | Per trie | `Lock(mt)` — insert, get, difference, clone, etc. |
| `SharedAccountMap::mtx` | `ErlNifMutex` | Per account map | `AccountMapLock` |
| `GlobalStripePool::s_mtx` | `std::mutex` | Process-global | PreAllocator stripe reuse |
| `ItemPool` internal | `std::recursive_mutex` | Per SharedState pool | COW / pair allocation |
| `PreAllocator` internal | `std::recursive_mutex` | Per tree stripe | Pair slab mutation |
| `stats_mutex` | `ErlNifMutex` | Global | DEBUG stats only |

**Independent domains:** `AccountMapLock` and `LockedStates::mtx` are never held together in current NIF code.

## Lock acquisition rules

| Path | Order | Notes |
|------|-------|-------|
| `difference_raw` | `locked_states_mutex` → snapshot pointers + `read_pins` → **release global** → `SharedState*` mutexes (address order) → unpin `read_pins` | `read_pins` prevents COW from consuming `difference` lifetime while global is dropped |
| `enter_lock` (dedup) | tree (`mt->locked`) → `locked_states_mutex` → pin `read_pins` on canonical → **release global** → bump `has_clone` / canonical switch | `read_pins` prevents reclaim until registration ref is taken |
| `leave_lock` / GC destructor | if `mt->locked`: `locked_states_mutex` → tree → decrement registration → erase map when `has_clone == 0`; else tree refcount only | Unlocked resources never touch `LockedStates` map |
| `merkletree_clone` | `Lock(parent)` | Dirty CPU scheduler; O(1) shallow resource alloc (`locked = false`) |
| `account_map_clone` | `AccountMapLock` → `Lock(parent_storage)` per trie (sequential) | Dirty scheduler; long hold |
| `account_map_lock` | `AccountMapLock` → `enter_lock` / `apply_canonical_lock` per unique `root_hash`; optional store trie after map lock released | Dirty scheduler; dedupes by root hash to avoid redundant canonical switches |
| `switch_local_to_canonical` | tree mutexes (address order) | Abandoned `SharedState` queued on `pending_orphans`; reclaimed via `try_reclaim_orphans` after `enter_lock` / `leave_lock` when mutex trylock succeeds and `has_clone == 0` |
| `account_map_uncompact_state` | `AccountMapLock(input)` → `materialize_storage` (brief tree lock) → `batch_insert` (state_store lock) | Dirty scheduler |
| `account_map_put/delete` | `AccountMapLock` only | May `release_resource` → async GC `leave_lock` |
| `account_map_list_difference_raw` | `SharedAccountMap*` mutexes (address order) → brief tree lock per entry for root read → release all before materialize | Dirty CPU; never hold map lock across `materialize_storage` |
| Insert / COW | Tree lock → ItemPool / PreAllocator / stripe pool | Same-thread nesting |

## Deadlock scenario registry

Each scenario has an ID, hypothesis, and test coverage target.

### A. Tree mutex + `LockedStates::mtx`

| ID | Scenario | Hypothesis | Covered by |
|----|----------|------------|------------|
| D-A1 | `enter_lock` dedup + `difference` on overlapping SharedStates | Global held during second tree wait (pre-fix F-5) | P9, S9, ExUnit lock concurrency |
| D-A2 | `leave_lock` (GC) + `difference` on same tree | Liveness stall: leave waits tree; diff never waits global | P11, S14, ExUnit D-A2 |
| D-A3 | `leave_lock` + `enter_lock` phase1 on same tree | Serialized on global | P10 smoke |
| D-A4 | `leave_lock`(global→T) + `enter_lock` switch(T,U) + `difference`(T,U) | Three-way liveness under heavy GC | P10 |
| D-A5 | Many concurrent `leave_lock` on distinct trees | Global mutex convoy | P11 |
| D-A6 | `enter_lock` dedup from 50+ clones | Canonical switch / refcount edge | P6, P14, ExUnit D-F2 |
| D-A7 | `lock` on already-locked tree | Re-entrant / double enter | S8 |

### B. Dual-tree ordering (`difference_raw`)

| ID | Scenario | Hypothesis | Covered by |
|----|----------|------------|------------|
| D-B1 | `difference(A,B)` vs `difference(B,A)` | Same address order | P2, P3 |
| D-B2 | `difference(A,B)` vs `difference(A,C)` — shared first tree | Second lock order by B vs C address | P10, ExUnit D-B2 |
| D-B3 | Long `difference` + concurrent insert | Insert waits tree held by difference | P5 |
| D-B4 | `difference` on same SharedState (early return) | No dual lock | S9 smoke |
| D-B5 | `difference` while `switch_local_to_canonical` holds both trees | Post-F-5 residual | P10 |

### C. Account map × tree mutex

| ID | Scenario | Risk | Covered by |
|----|----------|------|------------|
| D-C1 | `account_map_clone` + `difference` on shared storage | Tree mutex contention | P13 |
| D-C2 | `account_map_uncompact_state` + per-account `difference` | Independent domains unless storage shared | P12, S12, ExUnit D-C2 |
| D-C3 | `account_map_get` / `to_list` (materialize) + `difference` | Brief tree lock vs diff | S13 |
| D-C4 | `account_map_put` replacing storage + GC `leave_lock` | Async GC vs diff | P13 |
| D-C5 | `account_map_lock` / `account_map_clone` + concurrent `State.lock/1` | Correctness / writable fork | P14, P15, chain_state_uncompact_test, ExUnit D-C5, fuzz 16–18 |
| D-C6 | `cow_copy_accountmap` during concurrent `put` | Refcount race (F-4) | TSan on P4, P13 |
| D-C7 | `account_map_list_difference_raw` + `account_map_to_list` same map | Map mutex convoy / materialize stall | S20, ExUnit D-D7, D-C7 |
| D-C8 | Dual-map `list_difference` lock order (A,B) vs (B,A) | Ordering regression | S24, ExUnit D-C8 |

### D. Production composite (block sync)

| ID | Scenario | Covered by |
|----|----------|------------|
| D-D1 | `Chain.State.difference/2` (storage diffs per account) | P14 |
| D-D2 | `State.lock/1` on all account trees | P14 |
| D-D3 | D-D1 + D-D2 + uncompact concurrent | P14, P12, ExUnit D-D3 |
| D-D4 | compact → uncompact → clone → apply_difference | P14, S10, S11 |
| D-D5 | Storage get/insert + block import | P1, P5 |
| D-D6 | Dirty scheduler saturation | P15 |
| D-D7 | prepare_state composite (native diff + lock + legacy to_list) | S30, P17, ExUnit D-D7 |
| D-D8 | `list_difference` compact storage root compare (no full map materialize) | account_map_diff_test, S19 |

### E. C++ internal mutexes

| ID | Scenario | Covered by |
|----|----------|------------|
| D-E1 | Concurrent clone+insert on COW SharedState | P4 + TSan |
| D-E2 | `difference` + insert allocating pairs | P5 |
| D-E3 | Parallel tree discard + stripe pool | P7, P11 |
| D-E4 | Nested ItemPool lock in `fork_for_write` | By design (recursive) |

### F. Refcount / UAF masquerading as deadlock

| ID | Scenario | Covered by |
|----|----------|------------|
| D-F1 | `has_clone` mismatch during canonical switch | P9, S9, ExUnit dedup |
| D-F2 | Canonical ref reserved vs concurrent `leave_lock` | P9, ExUnit D-F2 |
| D-F3 | `release_storage_from_map` during delete vs diff | P13, caccount_map_lifetime_test |

## Remaining structural risk

`enter_lock` and `leave_lock` now both release the global mutex before blocking on tree mutexes. Monitor `nif_stats_raw/0` (`shared_states` vs `locked_states`) in production; sustained growth indicates a reclaim regression. `nif_stats_raw` is read-only (reclaim runs from lock/unlock paths only).

## CI / harness commands

| Job | Command |
|-----|---------|
| fuzz-quick | `mix run --no-start scripts/cmerkle_fuzz.exs -- --iterations 500 --seed 1` |
| stress-quick | `mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 1 --tasks 32` |
| stress-full | `mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 5 --tasks 48` |
| watchdog | `mix run --no-start scripts/cmerkle_deadlock_watchdog.exs -- -- cmd ...` |
| prepare_state | `mix run --no-start scripts/cmerkle_deadlock_watchdog.exs -- --timeout 120 mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 1 --tasks 48 --scenario P17` |
| ExUnit | `mix test test/cmerkle_nif_deadlock_test.exs --exclude external --no-start` |
