#!/bin/bash
# bench/run.sh — Run hung_detect with AOP profiling hooks
# Usage: ./bench/run.sh [hung_detect args...]
# Default: --all --json (stdout suppressed, bench stats on stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DYLIB="$SCRIPT_DIR/libhung_bench.dylib"
CONF="$SCRIPT_DIR/bench.conf"
BIN="$PROJECT_DIR/hung_detect"

# Build if needed
if [[ ! -f "$BIN" ]]; then
    echo "Building hung_detect..." >&2
    make -C "$PROJECT_DIR" build
fi
if [[ ! -f "$DYLIB" ]]; then
    echo "Building libhung_bench.dylib..." >&2
    make -C "$SCRIPT_DIR"
fi

# Default args: --all --json if none provided
ARGS=("${@:---all}" "${@:+}")
if [[ ${#@} -eq 0 ]]; then
    ARGS=(--all --json)
fi

# Run with AOP hooks injected
DYLD_INSERT_LIBRARIES="$DYLIB" HUNG_BENCH_CONF="$CONF" "$BIN" "${ARGS[@]}" 1>/dev/null
