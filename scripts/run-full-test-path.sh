#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RESULTS="${RESULTS_LOG:-$ROOT/test-path-results-$(date -u +%Y%m%dT%H%M%SZ).log}"
: > "$RESULTS"

failures=0

"$ROOT/scripts/run-regression-suite.sh" >>"$RESULTS" 2>&1 || failures=$((failures+1))

echo "=== SUMMARY ===" | tee -a "$RESULTS"
echo "results_log=$RESULTS" | tee -a "$RESULTS"
echo "failures=$failures" | tee -a "$RESULTS"
exit "$failures"
