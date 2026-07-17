# CAccountMap / CMerkleTree NIF

Agent-facing notes for the merkle account-map NIF (`priv/merkletree_nif.so`,
built from `c_src/` via `mix compile` / top-level `Makefile`).

See also [`c_src/LOCK_ORDER.md`](../c_src/LOCK_ORDER.md),
[`c_src/SECURITY_REVIEW.md`](../c_src/SECURITY_REVIEW.md), and the
implementation spec for difference/clone performance work:
[`docs/specs/change-state-diff-perf.md`](specs/change-state-diff-perf.md)
(cached compact storage roots, CompactStorage COW, state_trie-driven
`difference_full`).

## Ownership model

- `Chain.State` is backed by `CAccountMap`. Account storage tries and the state
  root trie live in C++. Elixir does **not** carry a separate `:store` field.
- Prefer map-owned storage APIs — never bare `merkletree` resources in production:
  - `Chain.State.storage_value/3`, `storage_put_map/2`, `storage_to_list/2`,
    `storage_get_proofs/3`, `storage_root_hash/2`, `state_root_hashes/1`
  - `CAccountMap` mirrors of the same (thin wrappers over merged NIFs)
- `Chain.State.hash/1` or `CAccountMap.root_hash/1` for the state root.
  Internal `state_trie` is never exported; Edge uses `state_root_hashes/1`.
- `account_map_get` / `to_list` return `{nonce, balance, storage_root_hash_bin32, code}`
  — the third element is a **32-byte hash**, never a live storage resource.
- `account_map_put/6` storage arg: `:keep` (meta-only) | `nil`/`[]` |
  `[{key32, value32}]` (genesis / hardfork / tests). Live bare-tree resources are
  not part of the public NIF surface.
- `account_map_storage/3` covers get / range / list / size via one NIF.
- `account_map_storage_roots/2` and `account_map_state_roots/1` return
  `<<root::32, hashes16::512>>`.
- `account_map_proof/2` (account) and `/3` (storage key).
- `account_map_compact/1` — one NIF for `Chain.State.compact/1`.
- Map-backed `%Chain.Account{}` values set `map_backed: true` and `root_hash`
  (struct field) via `Account.from_parts/4`. Storage is accessed only through
  `State.storage_*` / `CAccountMap.storage_*`. Edge `getaccount` /
  `getaccountroot` use `Account.root_hash/1` (no extra storage-roots NIF).
- Every chain definition exports `genesis_storage/0` (Devnet has slots;
  others return `%{}`). Genesis applies accounts then `State.storage_put_map/2`.

## Clone and lock

- `Chain.State.clone/1` forks a writable map. Use it after `Chain.State.lock/1`
  (cached peak / block sync) and for RPC / EdgeV2 / Shell speculative execution.
- Compact account storage uses `shared_ptr` COW: clone shares slot vectors until a
  write materializes unique live storage (parent keeps the shared compact object).
  Storage roots are cached on `CompactStorage` (seeded from Elixir `:root_hash` on
  uncompact). Meta-only `:keep` puts on compact accounts update `state_trie` via
  that cached root without materializing.
- `account_map_difference_full/2` is driven by the symmetric difference of
  `state_trie` leaves (not a full accounts scan), returns 6-tuples
  `{addr, side_a, side_b, storage_diff, root_a, root_b}`, and compares live
  storage via shared `SharedState*` when possible. `Chain.State.difference/2`
  consumes those roots (no second `storage_root_hash` pass).
- `account_map_storage_roots/2` does **not** materialize compact entries solely to
  read roots; it may build a temporary trie for the intermediate-hash blob.
- `lock/1` sets map-level `frozen` only. Mutations
  (`put` / `delete` / `apply_difference` / `storage_put_map`) reject frozen maps.
- `Chain.Transaction.apply/3` mutates state in place on an unlocked candidate.
- `Chain.State` is **mutable**: always `clone/1` before applying transactions on
  a shared cached state.

## Build

- NIF: `mix compile` → `elixir_make` → `c_src/` → `priv/merkletree_nif.so`
- Exports: `account_map_*` plus `count_zeros/1` and `nif_stats_raw/0`
  (`CMerkleTree.nif_stats/0`). No bare-tree test NIF mode.
- EVM binary: `evm/evm` (needs `libboost-dev`)
- `deps/libsecp256k1`: build once with `make -C deps/libsecp256k1/` (not via `mix`)

## Performance benches

Run without starting the full node (`mix run --no-start …`). Defaults target ~14k
accounts (prod jump-block scale).

| Script | Prod warning / path |
|--------|---------------------|
| `scripts/state_diff_bench.exs` | `State diff took longer than 1s…` / `State.difference` |
| `scripts/state_uncompact_bench.exs` | `state(uncompact:0x…) took Nms` / jump-block `State.uncompact` |
| `scripts/state_delta_apply_bench.exs` | `state(delta:0x…) took Nms` / clone + `apply_difference` + `normalize` |

Examples:

```bash
mix run --no-start scripts/state_uncompact_bench.exs -- --scenario sparse_jump
mix run --no-start scripts/state_delta_apply_bench.exs -- --scenario all --changed 20
mix run --no-start scripts/state_diff_bench.exs -- --scenario compact_small_delta
```
