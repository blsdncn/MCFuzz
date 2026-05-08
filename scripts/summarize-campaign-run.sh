#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <campaign-run-dir>" >&2
  exit 2
fi

RUN_DIR="$1"
SUMMARY="$RUN_DIR/run-summary.txt"
AFL_OUT="$RUN_DIR/aflnet-out"
FUZZER_STATS="$AFL_OUT/fuzzer_stats"
PLOT_DATA="$AFL_OUT/plot_data"
REPORT="$RUN_DIR/campaign-report.md"
COMPARISON="$RUN_DIR/coverage/comparison-vs-latest-baseline.txt"
HANG_ANALYSIS="$RUN_DIR/hang-analysis.txt"
HANG_REPLAY_CLASSIFICATION="$RUN_DIR/hang-replay-classification.txt"

[[ -s "$SUMMARY" ]] || { echo "missing run summary: $SUMMARY" >&2; exit 2; }

kv() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || { echo unavailable; return; }
  awk -F= -v k="$key" '$1 == k { print substr($0, length(k) + 2); found=1; exit } END { if (!found) print "unavailable" }' "$file"
}

stat_value() {
  local key="$1"
  [[ -f "$FUZZER_STATS" ]] || { echo unavailable; return; }
  awk -F: -v k="$key" '$1 ~ "^" k "[[:space:]]*$" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; found=1; exit } END { if (!found) print "unavailable" }' "$FUZZER_STATS"
}

iso_time() {
  local ts="$1"
  if [[ "$ts" =~ ^[0-9]+$ && "$ts" -gt 0 ]]; then
    date -u -d "@$ts" '+%Y-%m-%dT%H:%M:%SZ'
  else
    echo unavailable
  fi
}

plot_summary() {
  [[ -f "$PLOT_DATA" ]] || { echo "plot_rows=0"; echo "max_plot_gap_seconds=unavailable"; echo "last_plot_update=unavailable"; echo "last_new_path=unavailable"; return; }
  python3 - "$PLOT_DATA" <<'PY'
import sys, datetime
rows=[]
with open(sys.argv[1]) as f:
    for line in f:
        line=line.strip()
        if not line or line.startswith('#'):
            continue
        parts=[p.strip() for p in line.split(',')]
        if len(parts) < 13:
            continue
        rows.append((int(parts[0]), int(parts[3])))
if not rows:
    print('plot_rows=0')
    print('max_plot_gap_seconds=unavailable')
    print('last_plot_update=unavailable')
    print('last_new_path=unavailable')
    raise SystemExit
max_gap=0
for (a,_),(b,__) in zip(rows, rows[1:]):
    max_gap=max(max_gap,b-a)
last_update=rows[-1][0]
last_new=rows[0][0]
max_paths=rows[0][1]
for t,paths in rows[1:]:
    if paths > max_paths:
        max_paths=paths
        last_new=t
fmt=lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
print(f'plot_rows={len(rows)}')
print(f'max_plot_gap_seconds={max_gap}')
print(f'last_plot_update={fmt(last_update)}')
print(f'last_new_path={fmt(last_new)}')
PY
}

queue_by_hour() {
  local queue_dir="$AFL_OUT/queue"
  [[ -d "$queue_dir" ]] || { echo "queue_discoveries_by_hour=unavailable"; return; }
  python3 - "$queue_dir" <<'PY'
import sys, os
from pathlib import Path
paths=[p for p in Path(sys.argv[1]).iterdir() if p.is_file()]
if not paths:
    print('queue_discoveries_by_hour=')
    raise SystemExit
items=sorted(p.stat().st_mtime for p in paths)
start=items[0]
buckets={}
for t in items:
    h=int((t-start)//3600)
    buckets[h]=buckets.get(h,0)+1
print('queue_discoveries_by_hour=' + ','.join(f'{h}:{buckets[h]}' for h in sorted(buckets)))
PY
}

write_kv_lines() {
  local file="$1"
  shift
  for key in "$@"; do
    echo "- $key=$(kv "$file" "$key")"
  done
}

write_stat_lines() {
  for key in "$@"; do
    echo "- $key=$(stat_value "$key")"
  done
}

write_existing_kv_lines() {
  local file="$1"
  shift
  for key in "$@"; do
    local value
    value="$(kv "$file" "$key")"
    if [[ "$value" != "unavailable" ]]; then
      echo "- $key=$value"
    fi
  done
}

{
  echo "# Campaign Report"
  echo
  echo "## Verdict"
  write_kv_lines "$SUMMARY" campaign_status campaign_role campaign_seconds aflnet_exit_class target_failure_class velocity_alive_after_campaign
  echo
  echo "## Configuration"
  write_kv_lines "$SUMMARY" git_commit git_dirty aflnet_binary_mode campaign_seed_glob target_backend velocity_config jacoco_enabled
  echo
  echo "## AFLNet Progress"
  write_stat_lines execs_done execs_per_sec paths_total paths_found pending_total unique_crashes unique_hangs last_path last_hang
  echo
  echo "## Timeline"
  plot_summary | sed 's/^/- /'
  queue_by_hour | sed 's/^/- /'
  echo
  echo "## Feedback Metrics"
  write_kv_lines "$SUMMARY" state_feedback_evidence edge_feedback_evidence state_coverage_nodes state_coverage_edges state_coverage_node_growth state_coverage_edge_growth edge_coverage_metric_status edge_coverage_nonzero_cells edge_coverage_hit_count afl_fuzz_bitmap_changed_cells
  echo
  echo "## Target Diagnostics"
  write_kv_lines "$SUMMARY" velocity_fatal_exception_count handled_client_exception_count connection_reset_count timeout_count backend_or_session_error_count target_failure_class
  echo
  echo "## JaCoCo Coverage"
  if [[ -s "$COMPARISON" ]]; then
    write_existing_kv_lines "$COMPARISON" \
      comparison_status \
      line_covered_delta \
      classes_covered_by_campaign_not_baseline \
      packages_covered_by_campaign_not_baseline \
      line_details_dir \
      baseline_line_locations_instrumented \
      baseline_line_locations_covered \
      baseline_line_locations_missed_only \
      baseline_line_location_coverage_percent \
      campaign_line_locations_instrumented \
      campaign_line_locations_covered \
      campaign_line_locations_missed_only \
      campaign_line_location_coverage_percent \
      line_locations_covered_by_both \
      line_locations_covered_by_campaign_not_baseline \
      line_locations_covered_by_baseline_not_campaign \
      line_locations_covered_union \
      line_location_coverage_delta
  else
    echo "- comparison=not-generated"
  fi
  echo "- jacoco_coverage_phase=$(kv "$SUMMARY" jacoco_coverage_phase)"
  echo
  echo "## Hangs"
  echo "- unique_hangs=$(stat_value unique_hangs)"
  echo "- replayable_hangs=$(kv "$SUMMARY" replayable_hangs)"
  if [[ -s "$HANG_ANALYSIS" ]]; then
    echo "- hang_analysis=available"
    write_existing_kv_lines "$HANG_ANALYSIS" \
      hang_analysis_status \
      hang_analysis_mode \
      replayable_hang_count \
      unique_hang_hash_count \
      duplicate_hang_count \
      hang_size_min \
      hang_size_max \
      first_hang_artifact_time \
      last_hang_artifact_time
  else
    echo "- hang_analysis=not-generated"
  fi
  if [[ -s "$HANG_REPLAY_CLASSIFICATION" ]]; then
    echo "- hang_replay_classification=available"
    write_existing_kv_lines "$HANG_REPLAY_CLASSIFICATION" \
      hang_replay_classification_status \
      hang_replay_mode \
      replay_sample_requested \
      replay_sample_count \
      replay_success_count \
      replay_timeout_count \
      replay_nonzero_count \
      replay_sigsegv_count \
      replay_malformed_count \
      replay_no_response_exit_count \
      replay_send_failed_count \
      replay_recv_failed_count \
      replay_response_sequence_count \
      replay_initial_only_response_count \
      replay_no_response_sequence_count \
      replay_distinct_response_sequences \
      target_reachable_after_replay
  else
    echo "- hang_replay_classification=not-generated"
  fi
  echo
  echo "## Caveats"
  echo "- JaCoCo coverage phase: $(kv "$SUMMARY" jacoco_coverage_phase)"
  echo "- Campaign diagnostics are not AFLNet mutation feedback."
  echo "- Hang analysis is artifact-only unless a replay classifier is run."
  echo "- Hang replay classification is sample-based unless all hangs are replayed."
  echo
  echo "## Artifact Index"
  echo "- run_summary=$SUMMARY"
  echo "- fuzzer_stats=$FUZZER_STATS"
  echo "- plot_data=$PLOT_DATA"
  echo "- aflnet_out=$AFL_OUT"
  echo "- coverage_comparison=$COMPARISON"
  echo "- hang_analysis=$HANG_ANALYSIS"
  echo "- hang_replay_classification=$HANG_REPLAY_CLASSIFICATION"
} >"$REPORT"

echo "REPORT=$REPORT"
