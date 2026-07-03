#!/usr/bin/env bash
# Valgrind Callgrind profile of account_map_uncompact_state hot path (native harness).
# Matches chain_state_uncompact_test shape: N accounts, 1 storage slot each.
# BEAM+Valgrind is unreliable (JIT crash); this profiles the C++ hot path directly.
#
# Usage: ./scripts/profile_uncompact_callgrind.sh [account_count]
# Output: tmp/callgrind_uncompact.out
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p tmp

COUNT="${1:-${UNCOMPACT_PROFILE_COUNT:-14609}}"
OUT="$ROOT/tmp/callgrind_uncompact.out"
HARNESS="$ROOT/c_src/uncompact_harness.bin"

echo "==> Building native uncompact harness (-g)"
make -C c_src uncompact_harness.bin >/dev/null

rm -f "$OUT"

echo "==> Running Callgrind on native uncompact harness ($COUNT accounts)"
export UNCOMPACT_PROFILE_COUNT="$COUNT"
valgrind --tool=callgrind \
  --callgrind-out-file="$OUT" \
  --dump-instr=yes \
  "$HARNESS" "$COUNT" \
  2>"$ROOT/tmp/callgrind_valgrind.log"

if [[ ! -s "$OUT" ]]; then
  echo "ERROR: empty callgrind output" >&2
  exit 1
fi

IR=$(rg '^totals:' "$OUT" | awk '{print $2}')
echo "==> Wrote $OUT ($(wc -c <"$OUT") bytes, Ir=$IR)"
echo
echo "=== Top functions in NIF sources (inclusive >=0.5%) ==="
callgrind_annotate --inclusive=yes --auto=yes --threshold=0.5 "$OUT" \
  c_src/uncompact_harness.cpp c_src/rlp.cpp c_src/merkletree.cpp c_src/sha.cpp c_src/item_pool.cpp \
  | head -65
echo
echo "=== Hot path (exclusive, annotated sources) ==="
callgrind_annotate --auto=yes --threshold=0.3 "$OUT" \
  c_src/uncompact_harness.cpp c_src/rlp.cpp c_src/merkletree.cpp c_src/sha.cpp \
  | rg -i 'AccountHashCtx|compute|rlp_encode|sha\(|insert_item|root_hash|uncompact_harness|Tree::|pair_t|GlobalStripe|item_pool' \
  | head -50 || true
echo
echo "=== Global top (inclusive >=1%) ==="
callgrind_annotate --inclusive=yes --auto=yes --threshold=1 "$OUT" | head -35
echo
echo "Open in kcachegrind: kcachegrind $OUT"
