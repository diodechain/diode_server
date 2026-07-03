#!/usr/bin/env bash
# Valgrind Massif heap profile of uncompact hot path (native harness).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p tmp

COUNT="${1:-${UNCOMPACT_PROFILE_COUNT:-14609}}"
OUT="$ROOT/tmp/massif_uncompact.out"
HARNESS="$ROOT/c_src/uncompact_harness.bin"

make -C c_src uncompact_harness.bin >/dev/null
rm -f "$OUT"

echo "==> Running Massif on native uncompact harness ($COUNT accounts)"
valgrind --tool=massif \
  --massif-out-file="$OUT" \
  --pages-as-heap=yes \
  "$HARNESS" "$COUNT" \
  >/dev/null 2>"$ROOT/tmp/massif_valgrind.log"

echo "==> Wrote $OUT"
ms_print "$OUT" | head -95
