# Security review: `c_src/` (Merkle NIF)

**Scope:** Erlang NIF (`nif.cpp`), Merkle trie (`merkletree.*`, `item_pool.*`), SHA-256 (`sha.cpp`, `sha256_*`), allocators (`preallocator.hpp`), test binaries (`main.cpp`, `mem_harness.cpp`).  
**Threat model:** Code runs inside the Diode BEAM node. Callers include chain state, RPC/edge (`lib/network/edge_v2.ex`, `rpc.ex`), EVM, and tests. Any peer or RPC that can influence Merkle inputs or workload is in scope for DoS; memory corruption bugs are critical (same address space as the node).

---

## 1. NIF inventory (exports → Elixir)

### Production (always registered; ~21 entries)

| NIF name | Arity | Inputs | Callers (representative) |
|----------|-------|--------|---------------------------|
| `count_zeros` | 1 | binary | `Evm` (tx payload) |
| `nif_stats_raw` | 0 | — | `Network.Status` |
| `account_map_new` | 0 | — | `CAccountMap.new/0`, `Chain.State` |
| `account_map_clone` | 1 | account map resource | `CAccountMap.clone/1`, `Chain.State.clone/1` |
| `account_map_lock` | 1 | account map resource | `CAccountMap.lock/1` — `frozen` only (O(1)) |
| `account_map_get` | 2 | resource, 20-byte address | `{nonce, balance, storage_root_hash_bin32, code}` — never a live storage resource |
| `account_map_put` | 6 | resource, addr, nonce, balance, storage, code | Storage arg: resource \| `:keep` \| `nil`/`[]` \| `[{k,v}]`; rejects frozen |
| `account_map_delete` | 2 | resource, address | Rejects frozen |
| `account_map_root_hash` | 1 | resource | `Chain.State.hash/1` |
| `account_map_state_roots` | 1 | resource | 544-byte `<<root::32, hashes16::512>>`; Edge `getstateroots` |
| `account_map_size` | 1 | resource | `CAccountMap.size/1` |
| `account_map_to_list` | 1 | resource | `CAccountMap.to_list/1`, RPC account dumps |
| `account_map_difference_full` | 2 | two maps | `Chain.State.difference/2` |
| `account_map_apply_difference` | 2 | map, delta list | `Chain.State.apply_difference/2` |
| `account_map_compact` | 1 | account map | Dirty CPU; compact map for DB (OK frozen) |
| `account_map_uncompact_state` | 1 | compact or resource | Returns `{am, hash}` |
| `account_map_storage_put_map` | 2 | map, update list | EVM `su` hot path |
| `account_map_storage` | 3 | map, addr, spec | `{:get,k}` \| `{:range,k,n}` \| `:list` \| `:size` |
| `account_map_storage_roots` | 2 | map, addr | 544-byte `<<root::32, hashes16::512>>` |
| `account_map_proof` | 2 | map, addr | Account inclusion proof |
| `account_map_proof` | 3 | map, addr, key | Storage proof |

### Test/dev only (`-DCMERKLE_TEST_NIFS`; on unless `MIX_ENV=prod`)

Bare `merkletree` resource API (`new`, `insert_item_raw`, `get_item`, `get_range_raw`, `get_proofs_raw`, `difference_raw`, `lock`, `to_list`, `import_map`, `root_hash`, `hash`, `root_hashes_raw`, `bucket_count`, `size`, `clone`) plus debug (`struct_sizes_raw`, `memory_stats_raw`, `malloc_info_raw`). Used by ExUnit, fuzz, and stress scripts. Prod release builds omit these from `nif_funcs`.

**Frozen map:** `account_map_lock/1` sets map-level `frozen` only. Map mutations (`put`/`delete`/`apply_difference`/`storage_put_map`) fail while frozen. `get` / `to_list` export hashes only. Internal `state_trie` is never exported. `clone/1` forks writable wrappers for sync and speculative RPC/Edge/Shell.

**Trust:** Erlang validates some shapes (e.g. `to_bytes32`), but the NIF must treat all binaries and terms as hostile (size, allocation, scheduler impact).

---

## 2. Findings and CWE mapping

### Critical / high (addressed in this review where noted)

| ID | Topic | Severity | CWE | Notes / mitigation |
|----|--------|----------|-----|---------------------|
| F-1 | **`merkletree_import_map` map iterator leak** | High (resource leak / undefined behavior risk) | CWE-404 / CWE-775 | Early `return enif_make_badarg` inside `while` skipped `enif_map_iterator_destroy`. **Fixed:** `goto import_badarg` path destroys iterator. |
| F-2 | **`merkletree_difference` lock order** | High (deadlock) | CWE-833 | Concurrent `difference_raw(A,B)` vs `difference_raw(B,A)` could lock two trees in opposite order. **Fixed:** lock `first`/`second` by `SharedState*` address order, then use ordered locks. |

### Medium

| ID | Topic | Severity | CWE | Notes |
|----|--------|----------|-----|--------|
| F-3 | **`enif_binary_to_term` in `make_proof`** | Medium | CWE-502 / CWE-400 | Decodes Erlang term bytes embedded in proofs (`proof.type == 2`). Malicious or huge terms can stress atom table / allocation. Mitigations: trust only proofs from your own tree; consider max depth/size for `make_proof` recursion; optional caps via external format limits. |
| F-4 | **Recursive `make_proof` / `do_get_proofs`** | Low–medium | CWE-674 | Depth follows trie height (bounded by key path; practical depth large for adversarial trie). Stack exhaustion theoretically possible on extreme trees; monitor if accepting untrusted trees. |
| F-5 | **Interaction `LockedStates::mtx` vs tree mutexes** | Medium | CWE-833 | **Fixed:** `enter_lock` pins `has_clone` on local/canonical under global+tree lock, drops global before `switch_local_to_canonical`, and map entries hold a `has_clone` ref. `difference_raw` snapshots pointers under global, bumps `read_pins` (not `has_clone`), releases global, then acquires dual tree locks. `leave_lock` erases map entries under global, releases global, then detaches under tree lock only. |
| F-6 | **`make_writeable` COW under `Lock` RAII** | High | CWE-667 | **Fixed:** COW now transfers the held mutex (unlock old `SharedState`, lock new) instead of leaving `Lock` holding a destroyed mutex while mutating a forked tree. |
| F-7 | **`leave_lock` / canonical map UAF** | High | CWE-416 | **Fixed:** Map erase drops the map's `has_clone` ref; canonical pointers are re-validated before switch; `SharedState` is not deleted while referenced from the dedup map. |
| F-7b | **Abandoned `SharedState` after canonical switch** | High | CWE-404 | **Fixed:** orphan reclaim for standalone `CMerkleTree.lock` / `difference_raw` (test NIFs). `account_map_lock` is `frozen`-only. Monitor via `nif_stats_raw/0`. |
| F-6 | **Global `locked_states` / `stats_mutex` on upgrade** | Low | CWE-665 | `on_reload`/`on_upgrade` no-op; hot upgrade could leave stale globals. Acceptable if NIF not hot-reloaded. |

### Information disclosure / introspection

| ID | Topic | Severity | CWE | Notes |
|----|--------|----------|-----|--------|
| F-7 | **`malloc_info_raw`** | Low (info disclosure) | CWE-200 | Test/dev NIF only. Restrict in production if threat model requires. |
| F-8 | **`struct_sizes_raw` / `memory_stats_raw`** | Low | CWE-200 | Test/dev NIF only. |

### Denial of service

| ID | Topic | Severity | CWE | Notes |
|----|--------|----------|-----|--------|
| F-9 | **Unbounded work per NIF** | Medium | CWE-400 | Long-running exports use dirty schedulers: **CPU-bound** — `account_map_clone`, `lock`, `to_list`, `difference_full`, `apply_difference`, `storage_put_map`, `storage`, `proof`, `compact`, `uncompact_state`, `count_zeros`; test-only bare `difference_raw` / `to_list` / etc. Large dirty-NIF loops call `enif_consume_timeslice` every 512 iterations. Ensure adequate dirty CPU schedulers (`+SDcpu`). |

### Memory safety (manual review)

| ID | Topic | Severity | CWE | Notes |
|----|--------|----------|-----|--------|
| F-10 | **`bits_t::m_value[16]`** | Low | CWE-125 | `byte()` / `bit()` can read past logical `m_size` if misused; current trie paths keep prefix within constructed bounds. |
| F-11 | **`uint256_t(const char*)`** | Low | CWE-125 | Assumes 32 bytes; callers must pass 32-byte buffers (`value_binary.size == 32` enforced on insert paths). |
| F-12 | **`PreAllocator` / `malloc(STRIPE_SIZE * sizeof(T))`** | Low | CWE-119 | Placement new over stripes; `reinterpret_cast` is intentional. Clang analyzer warns `unix.MallocSizeof` (benign for this pattern). |
| F-13 | **`ItemPool` refcounts** | — | CWE-416 | Documented single-threaded w.r.t. `SharedState::mtx`; NIF holds `Lock` on mutations — consistent. `free_list` reuses ids after `nodes[id].reset()`. |

### Cryptography

| ID | Topic | Notes |
|----|--------|--------|
| F-14 | **SHA-256** | Implemented via `sha256_std.c` or asm (`__SHA__`). Not a constant-time comparison use case for secrets; Merkle uses hash as digest. NIST-style regression via `main.cpp` / ExUnit golden tests. |
| F-15 | **Side channels** | Standard SHA-256; timing not modeled as secret-agnostic for Merkle roots. |

### Dangerous APIs (grep)

- **`nif.cpp`:** `memcpy` in `make_binary` — size from caller; must match source buffer (call sites use known sizes).
- **`main.cpp` / `mem_harness.cpp`:** `sprintf` — test/harness only; not in NIF.
- **`sha256_std.c`:** `memcpy` in SHA update; `sprintf` for hex dump in debug path.
- **`preallocator.hpp`:** `reinterpret_cast` for stripe placement.

---

## 3. Resource destructor / locking (summary)

- `destruct_merkletree_type` → `locked_states->leave_lock(mt)` → `Lock` on `mt->shared_state->mtx` → `destroy_shared_state` may `delete` `SharedState` when `has_clone == 0`.
- Requires `mt->shared_state` non-null at destructor entry; normal paths maintain this until GC.
- **F-1** could have left iterators open; fixed to avoid VM resource leaks.

---

## 4. Tools run (results)

| Tool | Status | Result |
|------|--------|--------|
| **clang `--analyze`** (`-include cstdint`) | Run | `preallocator.hpp` malloc/sizeof informational warning (`MallocSizeof`); no critical path bugs reported. |
| **cppcheck** | Not installed | Install `cppcheck` package for CI (`cppcheck --enable=all`). |
| **scan-build** | Not installed | Install `clang-tools` / use `clang --analyze` as substitute. |
| **clang-tidy** | Not in PATH | Add `run-clang-tidy` or IDE integration with `bugprone-*`, `cert-*`. |
| **ASan+UBSan+LSan NIF** | Built | Targeted harnesses preferred over full `mix test` under ASan. |
| **Valgrind** (`memcheck`) on `c_src/test` | Run | 0 invalid access errors; harness may leave intentional trees. |
| **libFuzzer** | Run | `make fuzz_sha` — no crash in 5000 runs. |
| **readelf** | Run | `GNU_RELRO` present; consider `-Wl,-z,relro,-z,now` for full hardening. |

---

## 5. Build / hardening recommendations

- **Release flags:** Consider `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `-Wl,-z,relro,-z,now` for `merkletree_nif.so`.
- **Reproducibility:** `-march=native` in `OPTS` ties binaries to CPU; use generic `-march=x86-64` for release artifacts if needed.
- **Debug:** `DEBUG` / `MERKLE_DEBUG_POOL` — avoid in production builds.
- **Test NIFs:** Bare-tree / debug exports are compiled into `nif_funcs` only with `-DCMERKLE_TEST_NIFS` (non-prod by default).

---

## 6. Residual risk

- No automated CodeQL/Semgrep rules in-repo; recommend adding CI.
- Proof term decoding (`enif_binary_to_term`) remains a trust-boundary if proofs are ever deserialized from untrusted network bytes without verification.
