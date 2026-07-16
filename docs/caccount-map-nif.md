# CAccountMap / CMerkleTree NIF

Agent-facing notes for the merkle account-map NIF (`priv/merkletree_nif.so`,
built from `c_src/` via `mix compile` / top-level `Makefile`).

See also [`c_src/LOCK_ORDER.md`](../c_src/LOCK_ORDER.md) and
[`c_src/SECURITY_REVIEW.md`](../c_src/SECURITY_REVIEW.md).

## Ownership model

- `Chain.State` is backed by `CAccountMap`. Account storage tries and the state
  root trie live in C++. Elixir does **not** carry a separate `:store` field.
- Prefer map-owned storage APIs over bare `merkletree` resources:
  - `Chain.State.storage_get/3`, `storage_put_map/2`, `storage_to_list/2`,
    `storage_get_proofs/3`, `storage_root_hash/2`
  - `CAccountMap` mirrors of the same
- `Chain.State.hash/1` or `CAccountMap.root_hash/1` for the state root.
- `account_map_get` / `to_list` return `{nonce, balance, storage_root_hash_bin32, code}`
  — the third element is a **32-byte hash**, never a live storage resource.
- Map-backed `%Chain.Account{}` values have `storage_root: nil` and carry
  `:root_hash` when loaded from the map. Standalone tries are only for genesis /
  hardfork / import via `account_map_put/6`.

## Clone and lock

- `Chain.State.clone/1` forks a writable map. Use it after `Chain.State.lock/1`
  (cached peak / block sync) and for RPC / EdgeV2 / Shell speculative execution.
- `lock/1` sets map-level `frozen` only. Mutations
  (`put` / `put_meta` / `delete` / `apply_difference` / `storage_put_map`) reject
  frozen maps.
- `Chain.Transaction.apply/3` mutates state in place on an unlocked candidate.
- `Chain.State` is **mutable**: always `clone/1` before applying transactions on
  a shared cached state.

## Build

- NIF: `mix compile` → `elixir_make` → `c_src/` → `priv/merkletree_nif.so`
- EVM binary: `evm/evm` (needs `libboost-dev`)
- `deps/libsecp256k1`: build once with `make -C deps/libsecp256k1/` (not via `mix`)
