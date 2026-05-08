#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

wait_for_port_free() {
  local port="$1"
  for _ in $(seq 1 30); do
    if ! ss -tln | grep -q ":$port "; then
      return 0
    fi
    sleep 0.2
  done
  echo "port $port still in use before state-only campaign smoke" >&2
  ss -tlnp 2>/dev/null | grep ":$port " >&2 || true
  exit 1
}

wait_for_port_free 25565
wait_for_port_free 30066

AFLNET_FEEDBACK_MODE=state-only \
CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-20}" \
AFLNET_STATS_LOG_INTERVAL=1 \
  "$ROOT/scripts/run-aflnet-campaign-smoke.sh" >"$OUT" 2>&1

RUN_DIR="$(grep -E '^RUN_DIR=' "$OUT" | tail -1 | cut -d= -f2-)"
[[ -n "$RUN_DIR" ]] || { echo "missing RUN_DIR in campaign output" >&2; cat "$OUT" >&2; exit 1; }
SUMMARY="$RUN_DIR/run-summary.txt"
COMMAND="$RUN_DIR/aflnet-command.txt"
[[ -s "$SUMMARY" ]] || { echo "run summary missing" >&2; cat "$OUT" >&2; exit 1; }
[[ -s "$COMMAND" ]] || { echo "aflnet command missing" >&2; cat "$OUT" >&2; exit 1; }

grep -q '^campaign_status=PASS$' "$SUMMARY"
grep -q '^aflnet_feedback_mode=state-only$' "$SUMMARY"
grep -q '^aflnet_state_aware_enabled=yes$' "$SUMMARY"
grep -q '^aflnet_feedback_type=state-only$' "$SUMMARY"
grep -q '^state_feedback_evidence=observable$' "$SUMMARY"
grep -q '^edge_feedback_evidence=agent-loaded-no-shm$' "$SUMMARY"
grep -q '^agent_engine=NoOpCoverageEngine$' "$SUMMARY"
grep -q '^edge_coverage_metric_status=unavailable$' "$SUMMARY"

grep -q -- ' -P MC ' "$COMMAND"
grep -q -- ' -E ' "$COMMAND"
grep -q -- ' -q 3 ' "$COMMAND"
grep -q -- ' -s 3 ' "$COMMAND"
grep -q -- ' -b 2 ' "$COMMAND"
! grep -q -- ' -h 1 ' "$COMMAND"

grep -q 'PASS: AFLNet campaign smoke' "$OUT"
echo "PASS: AFLNet campaign state-only smoke"
