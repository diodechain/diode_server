# CMerkleTree memory evaluation report

This report summarizes runs of the tooling added for the memory-efficiency plan: Elixir RSS workloads (`scripts/cmerkle_memory_bench.exs`), native copy harness (`c_src/mem_harness.cpp`), stripe-size comparison (`scripts/compare_merkle_stripe_size.sh`), Valgrind Massif (optional), and NIF introspection (`CMerkleTree.struct_sizes/0`, `memory_stats/1`, `malloc_info/0`).

**Environment:** Linux, local dev run (single machine, not isolated from other OS noise). VmRSS is process-wide (BEAM + NIF + libc); incremental deltas between workloads isolate **relative** C++ pressure but absolute numbers include a large Erlang baseline.

**Fixes applied during evaluation:** `cmerkle_memory_bench.exs` now strips `mix run` argv noise (`*.exs`, `--`) so `--trees` / `--pairs` work; workloads **B** and **C** retain **all** forked/independent trees (not only the last survivor); workload **B** uses **one** locked base and repeated `clone → insert` inside a scoped function so the base handle is not pinned after forks diverge. Default `--trees` is **25** to keep RSS manageable when retaining full COW copies.

---

## 1. Static layout (NIF `struct_sizes/0`)

Measured C++ sizes (bytes):

| Field / object   | Size |
|------------------|-----:|
| `Item`           |  728 |
| `pair_t`         |   88 |
| `pair_list_t`    |  152 |
| `Tree` (shell)   |  136 |
| `MERKLE_STRIPE_SIZE` | 8 (default) |

`memory_stats/1` approximates `nodes × sizeof(Item) + pairs × sizeof(pair_t)` (does **not** include `std::vector` key storage in `pair_t`).

For a sample with **800 pairs** and **139** trie nodes: **≈171,592** bytes from that formula alone; keys add further heap not in this line.

---

## 2. Workload RSS (Elixir, `pairs=800`, `trees=25`, 2 iterations)

| Workload | Role | VmRSS (kb) typical | Notes |
|----------|------|-------------------:|-------|
| **A** | 25 `clone`s of one locked base (shared `SharedState`) | ~114,100–114,300 | Minimal duplication of C++ tree |
| **B** | 25 forks from one base: `clone` → insert one extra leaf (full COW copy each), all retained | ~119,400–119,700 | Near-duplicate trees (801 pairs each) |
| **C** | 25 independent trees (same keys, last value differs) | ~119,600–119,700 | Same order of retained data as B |
| **D** | Churn: build/`root_hash` 25×, keep last tree only | ~119,300–119,500 | Single tree retained; RSS still reflects allocator/BEAM high watermark |

**Delta A → B (retained forks):** about **+5,350 kb VmRSS** for **25** forks → **~214 kb per fork** at the process level (includes libc/allocator; aligns in order-of-magnitude with the **~171 kb** structural `memory_stats` increment for one extra duplicated tree of this shape).

**Interpretation:** Sharing handles (A) is far cheaper than retaining many COW-copied trees (B/C). Any optimization that avoids **full** `Tree` duplication on single-leaf updates (structural COW, persistent trie, or subtree interning) targets the gap between **A** and **B**.

---

## 3. Native harness (`mem_harness`: full `Tree` copy after building N pairs)

Runs **without** the BEAM; VmRSS read from `/proc/self/status` (small process).

| N (pairs) | Nodes (base=copy) | VmRSS delta (copy) kb |
|----------:|------------------:|----------------------:|
| 500       | 91                | 268 |
| 1,500     | 267               | 532 |
| 2,000     | 349               | 656 |
| 3,000     | 537               | 932 |

Copy cost scales roughly linearly with trie size (full duplicate of nodes + pairs).

---

## 4. Stripe size (`MERKLE_STRIPE_SIZE` 8 vs 32 vs 64, `N=2000`)

Native harness, same code path:

| Stripe | VmRSS delta (kb) after copy |
|-------:|----------------------------:|
| 8      | 656 |
| 32     | 648 |
| 64     | 652 |

**Finding:** **Neutral (N)** — changing stripe size did not materially change measured RSS in this scenario (<2% swing). Further tuning might help fragmentation under different churn, not shown here.

---

## 5. Valgrind Massif (optional, `mem_harness` N=1500)

Under Massif, peak **heap** for the small harness stayed on the order of **~1 MB** (chart peak ~910 KB; snapshot details mix libstdc++/program allocations). Use this for **malloc attribution** of the native binary, not for BEAM RSS.

---

## 6. Candidate impact matrix (plan backlog)

Ratings follow the plan: **S** strong (>10% on target workload where applicable), **M** moderate, **L** low, **N** neutral / not evidenced.

| # | Candidate | Rating | Evidence from this evaluation |
|---|-----------|--------|------------------------------|
| 1 | Structural COW / path copying | **S** (potential) | A vs B: **~5.35 MB** extra for **25** retained forks; native copy delta grows with **N** (§3). |
| 2 | Intern / content-addressed subtrees | **M** (potential) | Not implemented; would attack duplicate subtrees across **different** trees — high value if large shared prefixes. |
| 3 | Split `Item` leaf vs internal | **M** | `Item` = **728 B** × **node_count** dominates `memory_stats` model; internal nodes still carry leaf-shaped fields today. |
| 4 | Lazy / heap `hash_values[16]` | **M** | **512 B** of **728 B** per `Item` is hashes; savings scale with **node_count** on cold paths. |
| 5 | Smaller / variable `pair_list_t` | **L** | Fixed **152 B** per node + pointers; helps most when many sparse buckets. |
| 6 | Larger stripes / mmap arenas | **N** | §4: **8/32/64** stripes ~same RSS on harness. |
| 7 | Cross-tree allocator pools | **M** (churn) | Not isolated; D suggests allocator/BEAM retention can linger; worth profiling under destroy-heavy workloads. |
| 8 | Key interning (`bin_t`) | **M**–**L** | Not measured; **M** if keys repeat across trees, **L** if mostly unique 32-byte keys. |
| 9 | Prefix compression (`bits_t`) | **M** | Depth-dependent; not separately measured. |
| 10 | Drop redundant `key_hash` | **L** | **32 B × pair_count**; trades CPU vs RAM. |
| 11 | Struct packing / field order | **L** | Minor vs **728 B** `Item`. |
| 12 | Proof object pooling | **L** | Transient `unique_ptr` proof trees; affects peak under proof-heavy load, not steady RSS here. |
| 13 | Merge/collapse (`destroy_item` on shrink) | **L**–**N** | Code path already calls `destroy_item` when collapsing; revisit if profiling shows stranded nodes. |
| 14 | mmap bulk import arena | **M** (bulk) | Relevant for `import_map`-style loads; not covered by these micro-benches. |
| 15 | Tune `LEAF_SIZE` (arity) | **M** (workload) | Trade depth vs per-node width; needs separate sweep. |
| 16 | Erlang: avoid accidental unsharing | **S** (usage) | **A**: **25** clones of one locked tree share one `SharedState`; **B**: **25** retained forks each hold a full COW copy (~**+5.35 MB** VmRSS vs **A** in §2). |

---

## 7. Recommendations (priority)

1. **Product/API:** Prefer **shared** `SharedState` (clones, batched writes) until a mutation is required — largest win without C++ changes (aligns with **A vs B**).
2. **C++:** Prioritize **structural sharing** on `make_writeable` (path copy or interned DAG) for workloads like **B**.
3. **Quick wins:** **Lazy `hash_values`** and **leaf/internal `Item` split** — justified by §1 size breakdown; validate with `memory_stats` + RSS after each change.
4. **Deprioritize for RSS:** Stripe-only tuning (**§4**), unless Massif shows allocator hotspots in long-running churn tests.

---

## 8. Commands reference

```bash
# Elixir RSS CSV (default trees=25)
MIX_ENV=test mix run --no-start scripts/cmerkle_memory_bench.exs -- --workload all --samples 3

# Native copy cost
make -C c_src mem_harness
./c_src/mem_harness.bin 2000

# Stripe comparison
./scripts/compare_merkle_stripe_size.sh 2000

# Massif (optional)
./scripts/profile_cmerkle_massif.sh 1500
```

---

*Generated from automated runs on the evaluation host; re-run before release to capture your environment.*
