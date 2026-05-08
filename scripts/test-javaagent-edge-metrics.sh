#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_JAR="$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

[[ -f "$AGENT_JAR" ]] || { echo "Missing agent jar: $AGENT_JAR" >&2; exit 2; }

SRC_DIR="$TMPDIR/src/com/velocitypowered/edgecompat"
CLASS_DIR="$TMPDIR/classes"
METRICS_FILE="$TMPDIR/edge-metrics.txt"
LOG="$TMPDIR/javaagent.log"
mkdir -p "$SRC_DIR" "$CLASS_DIR"

cat >"$SRC_DIR/EdgeMetricSmoke.java" <<'JAVA'
package com.velocitypowered.edgecompat;

public final class EdgeMetricSmoke {
  public static void main(String[] args) {
    int result = 0;
    for (int i = 0; i < 100; i++) {
      if ((i & 1) == 0) {
        result += branch(i);
      } else {
        result -= branch(i);
      }
    }
    if (result == Integer.MIN_VALUE) {
      throw new AssertionError("unreachable guard");
    }
    System.out.println("EDGE_METRIC_SMOKE_OK " + result);
  }

  private static int branch(int value) {
    if (value % 3 == 0) {
      return value * 2;
    }
    return value + 1;
  }
}
JAVA

javac -d "$CLASS_DIR" "$SRC_DIR/EdgeMetricSmoke.java"

java \
  -javaagent:"$AGENT_JAR" \
  -Dafl.include='com.velocitypowered.*' \
  -Dafl.edgeMetricsFile="$METRICS_FILE" \
  -cp "$CLASS_DIR" \
  com.velocitypowered.edgecompat.EdgeMetricSmoke \
  >"$LOG" 2>&1

grep -q 'EDGE_METRIC_SMOKE_OK' "$LOG" || { echo "smoke program did not run" >&2; cat "$LOG" >&2; exit 1; }
grep -q '\[afl-mc-agent\] Agent ready' "$LOG" || { echo "javaagent did not report ready" >&2; cat "$LOG" >&2; exit 1; }
grep -q '\[afl-mc-agent\] Engine: NoOpCoverageEngine' "$LOG" || { echo "expected NoOpCoverageEngine outside AFLNet" >&2; cat "$LOG" >&2; exit 1; }
[[ -s "$METRICS_FILE" ]] || { echo "edge metrics file missing or empty: $METRICS_FILE" >&2; cat "$LOG" >&2; exit 1; }

assert_field() {
  local key="$1"
  local expected="$2"
  grep -qx "$key=$expected" "$METRICS_FILE" || {
    echo "Expected $key=$expected" >&2
    cat "$METRICS_FILE" >&2
    cat "$LOG" >&2
    exit 1
  }
}

assert_regex() {
  local regex="$1"
  grep -Eq "$regex" "$METRICS_FILE" || {
    echo "Expected metrics to match: $regex" >&2
    cat "$METRICS_FILE" >&2
    cat "$LOG" >&2
    exit 1
  }
}

assert_field edge_coverage_metric_status available
assert_field edge_coverage_metric_source javaagent-edge-metrics
assert_field edge_coverage_total_cells 65536
assert_regex '^edge_coverage_nonzero_cells=[1-9][0-9]*$'
assert_regex '^edge_coverage_hit_count=[1-9][0-9]*$'
assert_regex '^edge_coverage_density_percent=[0-9]+([.][0-9]+)?$'

if grep -q '^edge_coverage_metric_reason=' "$METRICS_FILE"; then
  echo "available edge metrics must not include an unavailable reason" >&2
  cat "$METRICS_FILE" >&2
  exit 1
fi

echo "PASS: javaagent edge metrics"
