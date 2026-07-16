# CAccountMap / CMerkleTree NIF

Agent-facing notes for the merkle account-map NIF (`priv/merkletree_nif.so`,
built from `c_src/` via `mix compile` / top-level `Makefile`).

See also [`c_src/LOCK_ORDER.md`](../c_src/LOCK_ORDER.md) and
[`c_src/SECURITY_REVIEW.md`](../c_src/SECURITY_REVIEW.md).

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
- `account_map_put/6` storage arg: resource | `:keep` (meta-only) | `nil`/`[]` |
  `[{key32, value32}]` (genesis / hardfork).
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
- `lock/1` sets map-level `frozen` only. Mutations
  (`put` / `delete` / `apply_difference` / `storage_put_map`) reject frozen maps.
- `Chain.Transaction.apply/3` mutates state in place on an unlocked candidate.
- `Chain.State` is **mutable**: always `clone/1` before applying transactions on
  a shared cached state.

## Build

- NIF: `mix compile` → `elixir_make` → `c_src/` → `priv/merkletree_nif.so`
- **Prod** (`MIX_ENV=prod`): ~21 map + misc exports only.
- **Dev/test** (non-prod): also registers bare-tree + debug NIFs via
  `-DCMERKLE_TEST_NIFS` (override with `CMERKLE_TEST_NIFS=0|1`). Mode stamp
  forces rebuild when the flag changes.
- EVM binary: `evm/evm` (needs `libboost-dev`)
- `deps/libsecp256k1`: build once with `make -C deps/libsecp256k1/` (not via `mix`)
