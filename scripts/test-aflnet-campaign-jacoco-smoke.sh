#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

wait_for_port_free() {
  local port="$1"
  for _ in $(seq 1 100); do
    if ! ss -tln | grep -q ":$port "; then
      return 0
    fi
    sleep 0.2
  done
  echo "port $port still in use before campaign JaCoCo smoke" >&2
  ss -tlnp 2>/dev/null | grep ":$port " >&2 || true
  exit 1
}

wait_for_port_free 25565
wait_for_port_free 30066

CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-20}" \
ENABLE_JACOCO=1 \
  "$ROOT/scripts/run-aflnet-campaign-smoke.sh" >"$OUT" 2>&1

RUN_DIR="$(grep -E '^RUN_DIR=' "$OUT" | tail -1 | cut -d= -f2-)"
[[ -n "$RUN_DIR" ]] || { echo "missing RUN_DIR in campaign output" >&2; cat "$OUT" >&2; exit 1; }
SUMMARY="$RUN_DIR/run-summary.txt"
[[ -s "$SUMMARY" ]] || { echo "run summary missing" >&2; cat "$OUT" >&2; exit 1; }

assert_summary() {
  local regex="$1"
  grep -Eq "$regex" "$SUMMARY" || {
    echo "Expected summary to match: $regex" >&2
    cat "$SUMMARY" >&2
    cat "$OUT" >&2
    exit 1
  }
}

assert_summary '^campaign_status=PASS$'
assert_summary '^aflnet_binary_mode=repo-built$'
assert_summary '^aflnet_exit_class=(clean|controlled-timeout|controlled-interrupt|controlled-sigterm)$'
assert_summary '^state_feedback_evidence=observable$'
assert_summary '^edge_feedback_evidence=shm-attached$'
assert_summary '^agent_engine=ShmCoverageEngine$'
assert_summary '^edge_coverage_metric_status=available$'
assert_summary '^edge_coverage_metric_source=javaagent-edge-metrics$'
assert_summary '^jacoco_enabled=1$'
assert_summary '^coverage_tool=jacoco$'
assert_summary '^coverage_role=human-readable-reporting$'
assert_summary '^jacoco_window_mode=whole-process$'
assert_summary '^campaign_role=coverage-reporting-smoke$'
assert_summary '^git_commit=([0-9a-f]{7,40}|unavailable)$'
assert_summary '^git_dirty=(yes|no|unavailable)$'
assert_summary '^target_backend=flying-squid$'
assert_summary '^velocity_config=.*velocity/velocity\.toml$'
assert_summary '^velocity_alive_after_campaign=yes$'
assert_summary '^velocity_process_status_before_jacoco_teardown=alive$'
assert_summary '^velocity_terminated_for_jacoco_dump=yes$'
assert_summary '^jacoco_coverage_phase=whole-process$'
assert_summary '^jacoco_coverage_includes_startup=yes$'
assert_summary '^jacoco_coverage_includes_preflight=yes$'
assert_summary '^jacoco_coverage_includes_aflnet_campaign=yes$'
assert_summary '^jacoco_coverage_includes_teardown=yes$'
assert_summary '^jacoco_exec=.+/logs/jacoco\.exec$'
assert_summary '^jacoco_report_xml=.+/coverage/jacoco\.xml$'
assert_summary '^jacoco_report_html=.+/coverage/html$'

JACOCO_EXEC="$(grep '^jacoco_exec=' "$SUMMARY" | cut -d= -f2-)"
JACOCO_XML="$(grep '^jacoco_report_xml=' "$SUMMARY" | cut -d= -f2-)"
JACOCO_HTML="$(grep '^jacoco_report_html=' "$SUMMARY" | cut -d= -f2-)"
[[ -s "$JACOCO_EXEC" ]] || { echo "JaCoCo exec missing: $JACOCO_EXEC" >&2; exit 1; }
[[ -s "$JACOCO_XML" ]] || { echo "JaCoCo XML missing: $JACOCO_XML" >&2; exit 1; }
[[ -n "$(find "$JACOCO_HTML" -type f -print -quit 2>/dev/null)" ]] || { echo "JaCoCo HTML missing: $JACOCO_HTML" >&2; exit 1; }

python3 - "$JACOCO_XML" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
covered = 0
for node in root.findall("counter"):
    covered += int(node.attrib.get("covered", "0"))
if covered <= 0:
    raise SystemExit("JaCoCo campaign XML has no covered counters")
PY

grep -q 'PASS: AFLNet campaign smoke' "$OUT"
echo "PASS: AFLNet campaign JaCoCo smoke"
