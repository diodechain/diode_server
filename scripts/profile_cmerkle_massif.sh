#!/usr/bin/env bash
# Valgrind Massif on the native mem harness (single-threaded malloc attribution).
# Usage: ./scripts/profile_cmerkle_massif.sh [pairs]
# Requires: valgrind, g++
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-800}"
cd "$ROOT/c_src"
make mem_harness.bin >/dev/null
OUT="$ROOT/c_src/massif_merkle.out"
valgrind --tool=massif --massif-out-file="$OUT" \
  ./mem_harness.bin "$N" >/dev/null
echo "Wrote $OUT"
ms_print "$OUT" | head -80
