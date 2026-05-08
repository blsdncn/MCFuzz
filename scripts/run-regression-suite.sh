#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${REGRESSION_LOG_DIR:-$ROOT/.tmp-regression-logs}"
mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/summary.txt"
: >"$SUMMARY"

run_test() {
  local name="$1"
  local timeout_s="$2"
  shift 2
  local log="$LOGDIR/${name}.log"
  local start
  start="$(date +%s)"
  echo "START $name timeout=${timeout_s}s"
  set +e
  timeout --signal=INT --kill-after=15s "${timeout_s}s" "$@" >"$log" 2>&1
  local rc=$?
  set -e
  local end dur status
  end="$(date +%s)"
  dur=$((end - start))
  if [[ $rc -eq 0 ]]; then
    status=PASS
  elif [[ $rc -eq 124 ]]; then
    status=TIMEOUT
  else
    status=FAIL
  fi
  echo "$name|$status|$rc|$dur|$log" >>"$SUMMARY"
  echo "END $name status=$status rc=$rc dur=${dur}s log=$log"
  [[ $rc -eq 0 ]]
}

cd "$ROOT"
run_test full-stack-smoke 300 ./scripts/test-full-stack-smoke.sh
run_test campaign-smoke 300 ./scripts/test-aflnet-campaign-smoke.sh
run_test velocity-javaagent-compat 300 ./scripts/test-velocity-javaagent-compatibility.sh
run_test jacoco-baseline 900 ./scripts/test-velocity-jacoco-baseline.sh
run_test jacoco-dual-agent-compat 900 ./scripts/test-velocity-dual-agent-compatibility.sh
run_test jacoco-campaign-whole 900 ./scripts/test-aflnet-campaign-jacoco-smoke.sh
run_test jacoco-campaign-epoch 900 ./scripts/test-aflnet-campaign-jacoco-epoch-smoke.sh
run_test jacoco-window-compare 1200 ./scripts/test-aflnet-campaign-jacoco-window-mode-comparison.sh
run_test jacoco-coverage-compare 300 ./scripts/test-jacoco-coverage-comparison.sh
run_test jacoco-line-coverage-compare 300 ./scripts/test-jacoco-line-coverage-comparison.sh

echo "OVERALL PASS" >>"$SUMMARY"
echo "OVERALL PASS"
