# CAccountMap NIF — lock order and deadlock scenario registry

This document inventories mutex layers in [`nif.cpp`](nif.cpp), documents acquisition order, and maps known deadlock / liveness scenarios to regression tests.

See also [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) and [`scripts/cmerkle_parallel_stress.exs`](../scripts/cmerkle_parallel_stress.exs).

## Mutex layers

| Mutex | Type | Scope | Used by |
|-------|------|-------|---------|
| `SharedState::mtx` | `ErlNifMutex` | Per storage / state trie | `Lock(mt)` during COW / storage reads / root hash; destructor `release_merkletree_shared` |
| `SharedAccountMap::mtx` | `ErlNifMutex` | Per account map | `AccountMapLock` |
| `GlobalStripePool::s_mtx` | `std::mutex` | Process-global | PreAllocator stripe reuse |
| `ItemPool` internal | `std::recursive_mutex` | Per SharedState pool | COW / pair allocation |
| `PreAllocator` internal | `std::recursive_mutex` | Per tree stripe | Pair slab mutation |
| `stats_mutex` | `ErlNifMutex` | Global | DEBUG stats + `nif_stats_raw` live counters |

Bare-tree Elixir NIFs (`new` / `insert` / `difference_raw` / `lock` / …) are gone. Storage tries exist only as map-owned internals. The old global `LockedStates` / orphan queue was removed with them.

## Lock acquisition rules

| Path | Order | Notes |
|------|-------|-------|
| Storage trie GC destructor | `release_merkletree_shared`: tree mutex → drop `has_clone` / delete when 0 | Immediate reclaim; no deferred orphan queue |
| `account_map_clone` | `AccountMapLock` → `fork_shared_accountmap` (`Lock` per parent storage / state_trie) | Dirty scheduler; writable fork even if parent `frozen` |
| `account_map_lock` | `AccountMapLock` → set `frozen=true` only (O(1); no per-trie seal) | Dirty scheduler; put/delete/storage_put_map reject via `frozen` |
| `account_map_storage_put_map` | `AccountMapLock` → reject if frozen → per-addr `write_storage_slot` → `update_state_trie_for_entry` | Dirty CPU; EVM `su` hot path |
| `account_map_storage` | `AccountMapLock` → read-only storage query (`:get`/`:range`/`:list`/`:size`) | Dirty CPU |
| `account_map_storage_roots` / `account_map_state_roots` | `AccountMapLock` → tree lock → root + 16 hashes blob | No live trie export |
| `account_map_proof` | `AccountMapLock` → account or storage proof | Dirty CPU; arities 2 and 3 |
| `account_map_uncompact_state` | `AccountMapLock(input)` → `materialize_storage` (brief tree lock) → `batch_insert` (state_store lock) | Dirty scheduler |
| `account_map_compact` | `AccountMapLock` (read-only; OK frozen) → per-account storage list via live tree lock or compact_storage slots | Dirty CPU |
| `account_map_put/delete` | `AccountMapLock` only; reject if `frozen`; storage arg may be `:keep` / list / `nil` | May `release_resource` → async GC `release_merkletree_shared` |
| `account_map_difference_full` | Dual map lock (`DualAccountMapLock`, address order) → snapshot sides → release → per-account storage diffs | Dirty CPU; never hold map lock across storage diff build |
| `account_map_apply_difference` | `AccountMapLock` → reject if `frozen` → storage/field writes (`write_storage_slot` → `make_writeable_locked`) | Dirty CPU |
| Insert / COW (internal) | Tree lock → ItemPool / PreAllocator / stripe pool | Same-thread nesting |

## Deadlock scenario registry

### C. Account map × tree mutex

| ID | Scenario | Risk | Covered by |
|----|----------|------|------------|
| D-C1 | `account_map_clone` + `difference_full` on shared storage | Tree mutex contention | P13 |
| D-C2 | `account_map_uncompact_state` + `difference_full` | Independent domains unless storage shared | P12, fuzz S3, ExUnit D-C2 |
| D-C3 | `account_map_get` / `to_list` (root hash export) + `difference_full` | No live storage export; brief hash compute | fuzz S4 |
| D-C4 | `account_map_put` replacing storage + GC `release_merkletree_shared` | Async GC vs diff | P13 |
| D-C5 | `account_map_lock` / `account_map_clone` + concurrent `State.lock/1` | Correctness / writable fork | P14, P15, chain_state_uncompact_test, ExUnit D-C5, fuzz 6–8 |
| D-C6 | Concurrent `put` / `apply_difference` on frozen map | Rejected via `make_writeable_accountmap` | TSan on P13 |
| D-C7 | `account_map_difference_full` + `account_map_to_list` same map | Map mutex convoy / materialize stall | fuzz S10, ExUnit D-D7, D-C7 |
| D-C8 | Dual-map `difference_full` lock order (A,B) vs (B,A) | Ordering regression | fuzz S14, ExUnit D-C8 |

### D. Production composite (block sync)

| ID | Scenario | Covered by |
|----|----------|------------|
| D-D1 | `Chain.State.difference/2` (storage diffs per account) | P14 |
| D-D2 | `State.lock/1` sets map `frozen` only (no per-trie seal; get exports root hashes not live storage) | P14 |
| D-D3 | D-D1 + D-D2 + uncompact concurrent | P14, P12, ExUnit D-D3 |
| D-D4 | compact → uncompact → clone → apply_difference | P14, fuzz S1–S2 |
| D-D6 | Dirty scheduler saturation | P15, P20 |
| D-D7 | prepare_state composite (native diff + lock + to_list) | fuzz S20, P17, ExUnit D-D7 |
| D-D8 | `difference_full` on compact storage | account_map_diff_test, fuzz S9 |
| D-L1 | `clone` after lock + storage_put_map + discard | `cmerkle_storage_map_test`, `cmerkle_lock_clone_regression_test`, P18L |
| D-L2 | `difference_full` + `apply_difference` round-trip | chain_state_merkle_test, account_map_diff_test |
| D-M1 | frozen map + eager clone writable fork | chain_state_merkle_test lock→clone |

### E. C++ internal mutexes

| ID | Scenario | Covered by |
|----|----------|------------|
| D-E1 | Concurrent clone+storage_put on COW SharedState | P13 + TSan |
| D-E3 | Parallel map discard + stripe pool | P12, P16 |
| D-E4 | Nested ItemPool lock in `fork_for_write` | By design (recursive) |

### F. Refcount / UAF masquerading as deadlock

| ID | Scenario | Covered by |
|----|----------|------------|
| D-F3 | `release_storage_from_map` during delete vs diff | P13, caccount_map_lifetime_test |

## Remaining structural risk

Monitor `nif_stats_raw/0` (`shared_states` / `merkletree_resources`) in production; sustained growth indicates a reclaim regression. Locked/orphan tuple slots stay zero (API shape preserved).

## CI / harness commands

| Job | Command |
|-----|---------|
| fuzz-quick | `mix run --no-start scripts/cmerkle_fuzz.exs -- --iterations 500 --seed 1` |
| stress-quick | `mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 1 --tasks 32` |
| stress-full | `mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 5 --tasks 48` |
| watchdog | `mix run --no-start scripts/cmerkle_deadlock_watchdog.exs -- -- cmd ...` |
| prepare_state | `mix run --no-start scripts/cmerkle_deadlock_watchdog.exs -- --timeout 120 mix run --no-start scripts/cmerkle_parallel_stress.exs -- --waves 1 --tasks 48 --scenario P17` |
| ExUnit | `mix test test/cmerkle_nif_deadlock_test.exs --exclude external --no-start` |
