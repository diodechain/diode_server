#!/usr/bin/env bash
# Long-running CMerkleTree NIF fuzzer with crash logging.
# Usage (from repository root):
#   ./scripts/cmerkle_fuzz.sh
#   MERKLE_FUZZ_ITERATIONS=5000 MERKLE_FUZZ_SEED=42 ./scripts/cmerkle_fuzz.sh
#   MERKLE_FUZZ_ASAN=1 ./scripts/cmerkle_fuzz.sh   # LD_PRELOAD libasan (noisy; best for debugging)
#
# Logs go to crash_logs/cmerkle_fuzz_<timestamp>.log (override with MERKLE_FUZZ_LOG).

set -o pipefail
cd "$(dirname "$0")/.." || exit 1

ITERATIONS="${MERKLE_FUZZ_ITERATIONS:-0}"
SEED="${MERKLE_FUZZ_SEED:-}"
MAX_KEYS="${MERKLE_FUZZ_MAX_KEYS:-900}"
LOG="${MERKLE_FUZZ_LOG:-}"

mkdir -p crash_logs
if [[ -z "$LOG" ]]; then
  LOG="crash_logs/cmerkle_fuzz_$(date -u +%Y%m%dT%H%M%SZ)_$$.log"
fi

ASAN_LIB=""
if [[ -n "${MERKLE_FUZZ_ASAN:-}" ]]; then
  ASAN_LIB="$(gcc -print-file-name=libasan.so 2>/dev/null || true)"
  if [[ -z "$ASAN_LIB" || ! -f "$ASAN_LIB" ]]; then
    echo "MERKLE_FUZZ_ASAN set but libasan.so not found; continuing without ASan." >&2
    ASAN_LIB=""
  fi
fi

write_header() {
  {
    echo "========== CMerkleTree fuzz crash log =========="
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname 2>/dev/null || echo unknown)"
    echo "pwd=$(pwd)"
    echo "git=$(git rev-parse HEAD 2>/dev/null || echo 'n/a')"
    echo "iterations=$ITERATIONS seed=${SEED:-random} max_keys=$MAX_KEYS"
    echo "MERKLE_FUZZ_ASAN=${MERKLE_FUZZ_ASAN:-} LD_PRELOAD=${ASAN_LIB:-}"
    echo "otp=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo '?')"
    echo "================================================"
    echo ""
  } | tee -a "$LOG"
}

write_footer() {
  local code=$1
  {
    echo ""
    echo "========== fuzz end =========="
    echo "exit_code=$code"
    echo "ended_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$code" != 0 ]]; then
      echo "NOTE: Non-zero exit may be Elixir exception (see FUZZ_ABORT) or BEAM killed by signal (NIF crash)."
    fi
    echo "log_file=$LOG"
    echo "=============================="
  } | tee -a "$LOG"
}

export MERKLE_FUZZ_ITERATIONS="$ITERATIONS"
export MERKLE_FUZZ_MAX_KEYS="$MAX_KEYS"
[[ -n "$SEED" ]] && export MERKLE_FUZZ_SEED="$SEED"

ARGS=(run --no-start scripts/cmerkle_fuzz.exs -- --iterations "$ITERATIONS" --max-keys "$MAX_KEYS")
if [[ -n "$SEED" ]]; then
  ARGS+=(--seed "$SEED")
fi

write_header

RUN_MIX=(mix "${ARGS[@]}")
if [[ -n "$ASAN_LIB" ]]; then
  export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1:halt_on_error=1}"
  export LD_PRELOAD="$ASAN_LIB${LD_PRELOAD:+:$LD_PRELOAD}"
fi

set +e
"${RUN_MIX[@]}" 2>&1 | tee -a "$LOG"
CODE=${PIPESTATUS[0]}
set -e

write_footer "$CODE"

if [[ "$CODE" != 0 ]]; then
  echo "Fuzz failed (exit $CODE). Full log: $LOG" >&2
fi

exit "$CODE"
