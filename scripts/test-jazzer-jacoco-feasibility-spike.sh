#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JAZZER_ROOT="$ROOT/velocity-jazzer-integration"

if [[ ! -d "$JAZZER_ROOT" ]]; then
  echo "SKIP: velocity-jazzer-integration missing"
  exit 0
fi

TMP_ROOT="$ROOT/.tmp-test-jazzer-jacoco-feasibility"
SPIKE_DIR="$TMP_ROOT/spike-stateful"
rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

TIME_LIMIT="${TIME_LIMIT:-20}"

MODE=stateful \
TIME_LIMIT="$TIME_LIMIT" \
RESET_OUTPUTS=1 \
SPIKE_ID="test-stateful" \
SPIKE_DIR="$SPIKE_DIR" \
"$ROOT/scripts/spike-jazzer-jacoco-feasibility.sh"

SUMMARY="$SPIKE_DIR/feasibility-summary.txt"
[[ -s "$SUMMARY" ]] || { echo "missing summary: $SUMMARY" >&2; exit 1; }

grep -q '^feasibility_status=PASS$' "$SUMMARY" || {
  echo "feasibility spike did not pass" >&2
  cat "$SUMMARY" >&2
  exit 1
}

EXEC_FILE="$(grep '^jacoco_exec=' "$SUMMARY" | head -n1 | cut -d= -f2-)"
XML_FILE="$(grep '^jacoco_xml=' "$SUMMARY" | head -n1 | cut -d= -f2-)"
COUNTERS="$(grep '^jacoco_xml_counter_lines=' "$SUMMARY" | head -n1 | cut -d= -f2-)"

[[ -n "$EXEC_FILE" && -s "$EXEC_FILE" ]] || { echo "missing jacoco exec output" >&2; exit 1; }
[[ -n "$XML_FILE" && -s "$XML_FILE" ]] || { echo "missing jacoco xml output" >&2; exit 1; }
[[ "${COUNTERS:-0}" -gt 0 ]] || { echo "jacoco xml has no counters" >&2; exit 1; }

echo "PASS: jazzer jacoco feasibility spike"
