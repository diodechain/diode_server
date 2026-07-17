# AGENTS.md

## Cursor Cloud specific instructions

Diode Server is an Elixir/OTP full blockchain node (Diode network) with native
C/C++ components. The single service is the node itself, which exposes an
Ethereum-compatible JSON-RPC endpoint plus the Diode PEER/EDGE protocols.

### Toolchain
- Managed by `asdf` per `.tool-versions` (Erlang `28.4.2`, Elixir `1.19.5`).
  asdf is initialized from `~/.bashrc`, so `mix`/`iex`/`erl` are on `PATH` in
  interactive shells; the asdf shims also work directly via
  `~/.asdf/shims`. Non-interactive scripts can `. "$HOME/.asdf/asdf.sh"` first
  (this is what `./run`, `./staging`, etc. already do).
- Erlang MUST be built with the `observer`/`et` apps present. `mix.exs` lists
  `:observer` in `extra_applications`, so a stripped OTP build (e.g.
  `--without-observer`) makes `mix test` and app startup fail with
  `could not find application file: observer.app`.
- The default `cc`/`c++` on this image is clang, which selects the gcc-14
  toolchain; `libstdc++-14-dev` must be installed or C/C++ deps (e.g. `ezstd`)
  fail to link with `cannot find -lstdc++`.

### Native components (built by the compiler, not the update script)
- `mix compile` runs `elixir_make` against the top-level `Makefile`, which
  builds the merkle-tree NIF (`priv/merkletree_nif.so`, from `c_src/`) and the
  EVM binary (`evm/evm`, needs `libboost-dev`).
- `deps/libsecp256k1` is NOT built by `mix`; build it once with
  `make -C deps/libsecp256k1/` (see `.github/workflows/ci.yml`). Build artifacts
  are gitignored and persist across sessions, so this is only needed after a
  clean checkout of that dep.
- **CAccountMap / state NIF semantics** (clone, lock, storage APIs, get shape):
  see [`docs/caccount-map-nif.md`](docs/caccount-map-nif.md). Difference/clone
  performance (cached compact roots, COW, trie-driven `difference_full`):
  [`docs/specs/change-state-diff-perf.md`](docs/specs/change-state-diff-perf.md).

### Lint
- `mix lint` = `compile` + `mix format --check-formatted` + `mix credo --only warning` + `mix dialyzer`.
- The git pre-commit hook (`githooks/pre-commit`) only runs
  `mix format --check-formatted`.
- First `mix dialyzer` run builds a PLT and is slow; subsequent runs are cached.

### Tests
- `make test` generates test PEM certs, then runs each `test/*_test.exs` file in
  a separate `mix test --max-failures 1` invocation (per-file isolation). Test
  env pins ports `RPC_PORT=18001`, `EDGE2_PORT=18003`, `PEER_PORT=18004`.
- For `Chain.State` / CAccountMap mutability and storage rules, see
  [`docs/caccount-map-nif.md`](docs/caccount-map-nif.md). Perf contract tests:
  `test/state_diff_perf_contract_test.exs`. Benches (no app start):
  `scripts/state_diff_bench.exs` (`State.difference`),
  `scripts/state_uncompact_bench.exs` (`state(uncompact:…)`),
  `scripts/state_delta_apply_bench.exs` (`state(delta:…)`).

### Running the node (dev mode)
- `./dev` runs `MIX_ENV=dev iex -S mix run` (wipes `data_dev/` first). For a
  non-interactive run use `MIX_ENV=dev mix run --no-halt`.
- Dev JSON-RPC listens on `0.0.0.0:3834` (the README's `8545` is stale; the
  default is `RPC_PORT=3834`). Dev `chain_id` is `5777` (`0x1691`).
- In dev mode `WORKER_MODE=poll`: blocks are produced on demand. Submitting a tx
  via `eth_sendRawTransaction` auto-triggers `Chain.Worker.work()` and mines a
  block immediately; you can also call `Chain.Worker.work()` from the iex shell.
- Devnet ships pre-funded genesis accounts (e.g. faucet
  `0xBADA81FAE68925FEC725790C34B68B5FACA90D45`) but their private keys are not in
  the repo; the min transaction fee is `0`, so `gasPrice: 0` transactions from
  fresh wallets are accepted.
