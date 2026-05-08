#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHOLE_OUT="$(mktemp)"
EPOCH_OUT="$(mktemp)"
trap 'rm -f "$WHOLE_OUT" "$EPOCH_OUT"' EXIT

wait_for_port_free() {
  local port="$1"
  for _ in $(seq 1 100); do
    if ! ss -tln | grep -q ":$port "; then
      return 0
    fi
    sleep 0.2
  done
  echo "port $port still in use before JaCoCo window comparison" >&2
  ss -tlnp 2>/dev/null | grep ":$port " >&2 || true
  exit 1
}

run_mode() {
  local mode="$1"
  local outfile="$2"
  wait_for_port_free 25565
  wait_for_port_free 30066
  CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-12}" \
  ENABLE_JACOCO=1 \
  JACOCO_WINDOW_MODE="$mode" \
    "$ROOT/scripts/run-aflnet-campaign-smoke.sh" >"$outfile" 2>&1
}

run_mode whole-process "$WHOLE_OUT"
run_mode campaign-epoch "$EPOCH_OUT"

WHOLE_RUN_DIR="$(grep -E '^RUN_DIR=' "$WHOLE_OUT" | tail -1 | cut -d= -f2-)"
EPOCH_RUN_DIR="$(grep -E '^RUN_DIR=' "$EPOCH_OUT" | tail -1 | cut -d= -f2-)"
[[ -n "$WHOLE_RUN_DIR" && -n "$EPOCH_RUN_DIR" ]] || {
  echo "missing run dir(s) in JaCoCo comparison test" >&2
  cat "$WHOLE_OUT" >&2
  cat "$EPOCH_OUT" >&2
  exit 1
}
WHOLE_SUMMARY="$WHOLE_RUN_DIR/run-summary.txt"
EPOCH_SUMMARY="$EPOCH_RUN_DIR/run-summary.txt"
[[ -s "$WHOLE_SUMMARY" && -s "$EPOCH_SUMMARY" ]] || { echo "missing summary in JaCoCo comparison test" >&2; exit 1; }

grep -Eq '^campaign_status=PASS$' "$WHOLE_SUMMARY"
grep -Eq '^campaign_status=PASS$' "$EPOCH_SUMMARY"
grep -Eq '^jacoco_window_mode=whole-process$' "$WHOLE_SUMMARY"
grep -Eq '^jacoco_window_mode=campaign-epoch$' "$EPOCH_SUMMARY"

WHOLE_XML="$(grep '^jacoco_report_xml=' "$WHOLE_SUMMARY" | cut -d= -f2-)"
EPOCH_XML="$(grep '^jacoco_report_xml=' "$EPOCH_SUMMARY" | cut -d= -f2-)"
[[ -s "$WHOLE_XML" && -s "$EPOCH_XML" ]] || { echo "missing JaCoCo XML(s) in JaCoCo comparison test" >&2; exit 1; }

python3 - "$WHOLE_XML" "$EPOCH_XML" <<'PY'
import sys
import xml.etree.ElementTree as ET

whole = ET.parse(sys.argv[1]).getroot()
epoch = ET.parse(sys.argv[2]).getroot()
metrics = ["INSTRUCTION", "LINE", "CLASS", "METHOD", "BRANCH"]

def covered(root, metric):
    for node in root.findall("counter"):
        if node.attrib.get("type") == metric:
            return int(node.attrib.get("covered", "0"))
    raise SystemExit(f"missing counter {metric}")

strictly_less = []
for metric in metrics:
    w = covered(whole, metric)
    e = covered(epoch, metric)
    if e <= 0:
        raise SystemExit(f"campaign-epoch covered count is zero for {metric}")
    if e > w:
        raise SystemExit(f"campaign-epoch {metric} covered={e} exceeded whole-process covered={w}")
    if e < w:
        strictly_less.append(metric)

if not strictly_less:
    raise SystemExit("campaign-epoch counters were not strictly smaller than whole-process on any coarse metric")

print("strictly_less=" + ",".join(strictly_less))
PY

echo "PASS: AFLNet campaign JaCoCo window-mode comparison"
