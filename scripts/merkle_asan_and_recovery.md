# CMerkleTree NIF: ASan builds and corrupted-node recovery

## AddressSanitizer / UndefinedBehaviorSanitizer (native)

From `c_src/`:

```bash
make test-asan    # C++ harness: full test + difference_stress (30 rounds)
make nif-asan     # builds ../priv/merkletree_nif.asan.so
```

`test-asan` sets `ASAN_OPTIONS=detect_leaks=0` because slab memory held in `GlobalStripePool` at process exit is reported as leaks by LeakSanitizer (benign for this allocator design).

## Instrumented NIF + Elixir (optional)

To run a subset of tests against the ASan NIF:

```bash
cd c_src && make nif-asan
cp ../priv/merkletree_nif.so ../priv/merkletree_nif.so.bak
cp ../priv/merkletree_nif.asan.so ../priv/merkletree_nif.so
export ASAN_OPTIONS=detect_leaks=0:verify_asan_link_order=0
mix test test/chain_state_merkle_test.exs test/cmerkletree_test.exs
mv ../priv/merkletree_nif.so.bak ../priv/merkletree_nif.so
```

If the VM fails to load the NIF, ensure the Erlang process can resolve `libasan` (same toolchain used to link `merkletree_nif.asan.so`). On some systems:

```bash
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libasan.so.8
```

(Adjust path to match your GCC’s libasan.)

## Recovering a node after bad deltas / malloc corruption

Symptoms: `apply_difference` raises on `^a = CMerkleTree.get(tree, key)` (delta old value does not match parent trie), or native heap errors in the NIF.

1. **Stop** the node.
2. **Find the last good block** (highest block number that still loads `Model.ChainSql.state/1` successfully, or the parent hash of the first failing block). Use logs, a backup, or binary search over block numbers.
3. **Roll the canonical peak back** to that block (see `Model.ChainSql.put_peak/1` in `lib/model/chainsql.ex`): it sets the normative peak and clears `number` on higher rows.
4. **Remove unnumbered orphan rows** if your deployment uses them: `Model.ChainSql.clear_alt_blocks/0` (`DELETE FROM blocks WHERE number IS NULL`).
5. **Restart** the VM (clears ETS caches such as `JumpState` used when replaying states).
6. **Resync** from peers so missing blocks after the good peak are fetched with valid deltas.

If a block was **persisted while the NIF was buggy**, its stored delta may be permanently inconsistent: rolling back and resyncing is required; fixing the NIF does not repair bad `state` blobs already written.
