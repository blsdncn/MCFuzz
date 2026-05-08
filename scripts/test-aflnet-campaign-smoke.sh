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
  echo "port $port still in use before campaign smoke" >&2
  ss -tlnp 2>/dev/null | grep ":$port " >&2 || true
  exit 1
}

wait_for_port_free 25565
wait_for_port_free 30066

CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-20}" \
AFLNET_STATS_LOG_INTERVAL=1 \
  "$ROOT/scripts/run-aflnet-campaign-smoke.sh" >"$OUT" 2>&1

RUN_DIR="$(grep -E '^RUN_DIR=' "$OUT" | tail -1 | cut -d= -f2-)"
[[ -n "$RUN_DIR" ]] || { echo "missing RUN_DIR in campaign output" >&2; cat "$OUT" >&2; exit 1; }
WATCH_STATS_CMD="$(grep -E '^WATCH_STATS_CMD=' "$OUT" | tail -1 | cut -d= -f2-)"
[[ -n "$WATCH_STATS_CMD" ]] || { echo "missing WATCH_STATS_CMD in campaign output" >&2; cat "$OUT" >&2; exit 1; }
[[ -d "$RUN_DIR" ]] || { echo "campaign run directory missing: $RUN_DIR" >&2; cat "$OUT" >&2; exit 1; }
[[ -d "$RUN_DIR/aflnet-out" ]] || { echo "AFLNet output directory missing" >&2; cat "$OUT" >&2; exit 1; }
[[ -s "$RUN_DIR/run-summary.txt" ]] || { echo "run summary missing" >&2; cat "$OUT" >&2; exit 1; }
[[ -s "$RUN_DIR/logs/velocity.log" ]] || { echo "Velocity log missing" >&2; cat "$OUT" >&2; exit 1; }
[[ -s "$RUN_DIR/logs/flying-squid.log" ]] || { echo "backend log missing" >&2; cat "$OUT" >&2; exit 1; }
[[ -s "$RUN_DIR/logs/aflnet.log" ]] || { echo "AFLNet log missing" >&2; cat "$OUT" >&2; exit 1; }

grep -q '^campaign_status=PASS$' "$RUN_DIR/run-summary.txt"
grep -Eq '^execs_done=[1-9][0-9]*$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_protocol=MC$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_exit_class=(clean|controlled-timeout|controlled-interrupt|controlled-sigterm)$' "$RUN_DIR/run-summary.txt"
! grep -Eq '^aflnet_exit=139$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_binary_mode=repo-built$' "$RUN_DIR/run-summary.txt"
grep -Eq '^campaign_role=smoke$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_feedback_mode=state-aware$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_state_aware_enabled=yes$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_feedback_type=state-aware\+code$' "$RUN_DIR/run-summary.txt"
grep -Eq '^git_commit=([0-9a-f]{7,40}|unavailable)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^git_dirty=(yes|no|unavailable)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^target_backend=flying-squid$' "$RUN_DIR/run-summary.txt"
grep -Eq '^velocity_config=.*velocity/velocity\.toml$' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_poll_wait_ms=' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_socket_timeout_usec=' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_startup_delay_usec=' "$RUN_DIR/run-summary.txt"
grep -Eq '^aflnet_stats_log=.+/logs/watch-stats\.log$' "$RUN_DIR/run-summary.txt"
[[ -s "$RUN_DIR/logs/watch-stats.log" ]] || { echo "watch stats log missing" >&2; cat "$RUN_DIR/run-summary.txt" >&2; exit 1; }
grep -Eq '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \[aflnet-stats\] ' "$RUN_DIR/logs/watch-stats.log" || { echo "watch stats log lacks timestamped stats" >&2; cat "$RUN_DIR/logs/watch-stats.log" >&2; exit 1; }
grep -Eq '^state_feedback_evidence=' "$RUN_DIR/run-summary.txt"
grep -Eq '^agent_engine=ShmCoverageEngine$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_feedback_evidence=shm-attached$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_metric_status=available$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_nodes=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_edges=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_initial_nodes=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_final_nodes=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_node_growth=-?[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_initial_edges=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_final_edges=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_edge_growth=-?[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^state_coverage_new_paths=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^afl_bitmap_metric_status=available$' "$RUN_DIR/run-summary.txt"
grep -Eq '^afl_bitmap_cvg_percent=([0-9]+([.][0-9]+)?|unavailable)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^afl_bitmap_nonzero_cells=unavailable$' "$RUN_DIR/run-summary.txt"
grep -Eq '^afl_bitmap_nonzero_cells_reason=fuzz_bitmap_is_virgin_map_not_trace_bitmap$' "$RUN_DIR/run-summary.txt"
grep -Eq '^afl_fuzz_bitmap_changed_cells=([0-9]+|unavailable)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^afl_fuzz_bitmap_size=([0-9]+|unavailable)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_coverage_metric_status=available$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_coverage_metric_source=javaagent-edge-metrics$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_coverage_total_cells=65536$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_coverage_nonzero_cells=[1-9][0-9]*$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_coverage_hit_count=[1-9][0-9]*$' "$RUN_DIR/run-summary.txt"
grep -Eq '^edge_coverage_density_percent=[0-9]+([.][0-9]+)?$' "$RUN_DIR/run-summary.txt"
grep -Eq '^fatal_velocity_log_count=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^velocity_process_status=(alive|exited|missing|unknown)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^velocity_process_death=(yes|no)$' "$RUN_DIR/run-summary.txt"
grep -Eq '^velocity_fatal_exception_count=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^handled_client_exception_count=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^connection_reset_count=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^timeout_count=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^backend_or_session_error_count=[0-9]+$' "$RUN_DIR/run-summary.txt"
grep -Eq '^target_failure_class=(clean|handled-rejections|timeout-heavy|connection-reset-heavy|fatal-log|process-death|unknown)$' "$RUN_DIR/run-summary.txt"

grep -q 'PASS: AFLNet campaign smoke' "$OUT"
"$ROOT/scripts/watch-aflnet-stats.sh" --once "$RUN_DIR" | grep -Eq '^\[aflnet-stats\] execs_done=[0-9]+ execs_per_sec=[^ ]+ paths_total=[^ ]+ paths_found=[^ ]+ bitmap_cvg=[^ ]+ n_nodes=[^ ]+ n_edges=[^ ]+ crashes=[0-9]+ hangs=[0-9]+'
"$ROOT/scripts/test-full-stack-smoke.sh" >/dev/null
