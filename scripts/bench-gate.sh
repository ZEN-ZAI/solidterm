#!/usr/bin/env bash
# Phase 0: stub. Fails CI only when hot_* benchmarks regress >10% vs baseline.
set -euo pipefail
input="${1:-/dev/stdin}"
echo "bench-gate: skipped (no benches yet — implement after first Criterion target lands in M1)"
# Future impl: parse $input; exit 1 only on hot_* regression > threshold
exit 0
