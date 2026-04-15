#!/usr/bin/env bash
# Rebuild mem_harness with two MERKLE_STRIPE_SIZE values and print VmRSS delta lines.
# Allocator experiment helper (plan: candidate stripe size / mmap arenas).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-2500}"
cd "$ROOT/c_src"
OPTS="merkletree.cpp sha.cpp -g -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++"
for S in 8 32 64; do
  echo "=== MERKLE_STRIPE_SIZE=$S ==="
  g++ -std=c++17 -I. -O2 -g -DMERKLE_STRIPE_SIZE="$S" -o "mem_stripes_${S}.bin" mem_harness.cpp $OPTS
  "./mem_stripes_${S}.bin" "$N"
done
