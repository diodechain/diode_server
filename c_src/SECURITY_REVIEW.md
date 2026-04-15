# Security review: `c_src/` (Merkle NIF)

**Scope:** Erlang NIF (`nif.cpp`), Merkle trie (`merkletree.*`, `item_pool.*`), SHA-256 (`sha.cpp`, `sha256_*`), allocators (`preallocator.hpp`), test binaries (`main.cpp`, `mem_harness.cpp`).  
**Threat model:** Code runs inside the Diode BEAM node. Callers include chain state, RPC/edge (`lib/network/edge_v2.ex`, `rpc.ex`), EVM, and tests. Any peer or RPC that can influence Merkle inputs or workload is in scope for DoS; memory corruption bugs are critical (same address space as the node).

---

## 1. NIF inventory (exports → Elixir)

| NIF name | Arity | Inputs | Callers (representative) |
|----------|-------|--------|---------------------------|
| `new` | 0 | — | `CMerkleTree.new/0` |
| `insert_item_raw` | 3 | resource, key binary, value binary (must be 32 bytes) | `insert`, `insert_items` |
| `get_item` | 2 | resource, key binary | `get/2` |
| `get_proofs_raw` | 2 | resource, key binary | `get_proofs/2` → RPC, edge |
| `difference_raw` | 2 | two resources | `difference/2`, `Chain.State` |
| `lock` | 1 | resource | `CMerkleTree.lock/1`, scripts |
| `to_list` | 1 | resource | `to_list`, RPC |
| `import_map` | 2 | resource, map (bin→bin pairs, values 32 bytes) | `from_map` |
| `root_hash` | 1 | resource | Widespread |
| `hash` | 1 | binary | hashing helpers |
| `root_hashes_raw` | 1 | resource | `root_hashes/1`, edge |
| `bucket_count` | 1 | resource | tests |
| `size` | 1 | resource | Widespread |
| `clone` | 1 | resource | `clone`, account storage |
| `count_zeros` | 1 | binary | `Evm` (tx payload) |
| `struct_sizes_raw` | 0 | — | tests, benches |
| `memory_stats_raw` | 1 | resource | tests, benches |
| `malloc_info_raw` | 0 | — | tests, `cmerkle_memory_bench.exs` |

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
| F-5 | **Interaction `LockedStates::mtx` vs tree mutexes** | Medium | CWE-833 | `enter_lock` takes global mutex then per-tree mutex; `difference` no longer inverts per-tree order (F-2). Still document: no lock held across `enif_*` that could re-enter NIF. |
| F-6 | **Global `locked_states` / `stats_mutex` on upgrade** | Low | CWE-665 | `on_reload`/`on_upgrade` no-op; hot upgrade could leave stale globals. Acceptable if NIF not hot-reloaded. |

### Information disclosure / introspection

| ID | Topic | Severity | CWE | Notes |
|----|--------|----------|-----|--------|
| F-7 | **`malloc_info_raw`** | Low (info disclosure) | CWE-200 | Exposes glibc allocator XML; useful for debugging, aids heap fingerprinting. Restrict in production if threat model requires. |
| F-8 | **`struct_sizes_raw` / `memory_stats_raw`** | Low | CWE-200 | Exposes struct sizes and node/pair counts; aids exploit planning. Same as F-7. |

### Denial of service

| ID | Topic | Severity | CWE | Notes |
|----|--------|----------|-----|--------|
| F-9 | **Unbounded work per NIF** | Medium | CWE-400 | `import_map`, `to_list`, `difference`, `count_zeros` scale with map/tree/binary size. No `enif_consume_timeslice`. Mitigation: dirty NIF flags or batching at Elixir layer for untrusted inputs. |

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
| **ASan+UBSan+LSan NIF** | Built | `make nif CXXFLAGS='... -fsanitize=address,undefined,leak ...'` links; **loading under full `mix test` without `--no-start` failed** (app boot + ASan runtime interaction). Use targeted tests or `mix test --no-start` with sanitizer NIF if extended validation is needed. |
| **Valgrind** (`memcheck`) on `c_src/test` | Run | 0 invalid access errors; large “definitely lost” from harness not freeing final tree (test artifact). |
| **libFuzzer** | Run | `make fuzz_sha` — `fuzz_sha.cpp` + `sha.cpp`, 5000 runs, no crash. |
| **readelf** | Run | `GNU_RELRO` present; `BIND_NOW` not set — use `-Wl,-z,relro,-z,now` for full hardening if desired. |

---

## 5. Build / hardening recommendations

- **Release flags:** Consider `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `-Wl,-z,relro,-z,now` for `merkletree_nif.so`.
- **Reproducibility:** `-march=native` in `OPTS` ties binaries to CPU; use generic `-march=x86-64` (or equivalent) for release artifacts if needed.
- **Debug:** `DEBUG` / `MERKLE_DEBUG_POOL` — avoid in production builds.
- **Sanitizer CI:** Job that builds NIF with sanitizers and runs `mix test test/cmerkletree_test.exs --no-start`.

---

## 6. Code changes made during review

1. **`merkletree_import_map`:** iterator destroyed on all error paths (`import_badarg`).
2. **`merkletree_difference`:** consistent lock ordering by `SharedState*` address.
3. **`fuzz_sha.cpp` + Makefile `fuzz_sha` target** for ongoing fuzzing of SHA.

---

## 7. Residual risk

- No automated CodeQL/Semgrep rules in-repo; recommend adding CI.
- Full BEAM + ASan NIF requires runtime tuning (`ASAN_OPTIONS`, possibly `LD_PRELOAD`); use native harnesses for sanitizer depth.
- Proof term decoding (`enif_binary_to_term`) remains a trust-boundary if proofs are ever deserialized from untrusted network bytes without verification.
