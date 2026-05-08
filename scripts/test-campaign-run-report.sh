#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RUN_DIR="$TMPDIR/run"
AFL_OUT="$RUN_DIR/aflnet-out"
mkdir -p "$AFL_OUT/queue" "$RUN_DIR/coverage"

cat >"$RUN_DIR/run-summary.txt" <<'SUMMARY'
campaign_status=PASS
campaign_role=coverage-reporting-smoke
campaign_seconds=120
aflnet_exit_class=controlled-timeout
execs_done=100
execs_per_sec=5.00
queue_paths_total=4
queue_paths_found=3
state_feedback_evidence=observable
edge_feedback_evidence=shm-attached
agent_engine=ShmCoverageEngine
state_coverage_nodes=5
state_coverage_edges=7
state_coverage_node_growth=2
state_coverage_edge_growth=3
edge_coverage_metric_status=available
edge_coverage_nonzero_cells=42
edge_coverage_hit_count=1000
target_failure_class=timeout-heavy
velocity_alive_after_campaign=yes
replayable_hangs=2
jacoco_enabled=1
jacoco_coverage_phase=whole-process
SUMMARY

cat >"$AFL_OUT/fuzzer_stats" <<'STATS'
start_time        : 1000
last_update       : 1120
execs_done        : 100
execs_per_sec     : 5.00
paths_total       : 4
paths_found       : 3
unique_crashes    : 0
unique_hangs      : 2
last_path         : 1090
last_hang         : 1080
STATS

cat >"$AFL_OUT/plot_data" <<'PLOT'
# unix_time, cycles_done, cur_path, paths_total, pending_total, pending_favs, map_size, unique_crashes, unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges
1000, 0, 0, 1, 1, 0, 1.00%, 0, 0, 1, 1.0, 3, 4
1030, 0, 1, 2, 2, 0, 1.10%, 0, 1, 2, 2.0, 4, 5
1090, 0, 2, 4, 3, 0, 1.20%, 0, 2, 3, 5.0, 5, 7
PLOT

: >"$AFL_OUT/queue/id:000000,orig:seed.bin"
: >"$AFL_OUT/queue/id:000001,+cov"
: >"$AFL_OUT/queue/id:000002,+cov"
touch -d @1000 "$AFL_OUT/queue/id:000000,orig:seed.bin"
touch -d @1030 "$AFL_OUT/queue/id:000001,+cov"
touch -d @1090 "$AFL_OUT/queue/id:000002,+cov"

cat >"$RUN_DIR/coverage/comparison-vs-latest-baseline.txt" <<'CMP'
comparison_status=PASS
line_covered_delta=12
classes_covered_by_campaign_not_baseline=3
packages_covered_by_campaign_not_baseline=1
line_details_dir=/tmp/line-details
baseline_line_locations_covered=10
campaign_line_locations_covered=14
line_locations_covered_by_campaign_not_baseline=6
line_locations_covered_by_baseline_not_campaign=2
line_locations_covered_by_both=8
line_locations_covered_union=16
line_location_coverage_delta=4
CMP

cat >"$RUN_DIR/hang-analysis.txt" <<'HANG'
hang_analysis_status=PASS
hang_analysis_mode=artifact-only-not-replayed
replayable_hang_count=2
unique_hang_hash_count=1
duplicate_hang_count=1
hang_interpretation=artifact-only-not-replayed
HANG

cat >"$RUN_DIR/hang-replay-classification.txt" <<'REPLAY'
hang_replay_classification_status=PASS
hang_replay_mode=sample-replay
replay_sample_requested=2
replay_sample_count=2
replay_success_count=1
replay_timeout_count=0
replay_nonzero_count=1
replay_sigsegv_count=0
replay_malformed_count=0
replay_no_response_exit_count=1
replay_send_failed_count=0
replay_recv_failed_count=0
replay_response_sequence_count=1
replay_initial_only_response_count=0
replay_no_response_sequence_count=1
replay_distinct_response_sequences=1
target_reachable_after_replay=yes
hang_replay_interpretation=mixed
sample_1_file=id:000001,hang
sample_1_exit=0
sample_1_log=/tmp/noise.log
REPLAY

"$ROOT/scripts/summarize-campaign-run.sh" "$RUN_DIR" >/dev/null
REPORT="$RUN_DIR/campaign-report.md"
[[ -s "$REPORT" ]] || { echo "campaign report missing" >&2; exit 1; }

assert_contains() {
  local expected="$1"
  grep -Fq "$expected" "$REPORT" || {
    echo "Expected report to contain: $expected" >&2
    cat "$REPORT" >&2
    exit 1
  }
}

assert_contains '# Campaign Report'
assert_contains '## Verdict'
assert_contains 'campaign_status=PASS'
assert_contains 'aflnet_exit_class=controlled-timeout'
assert_contains '## Timeline'
assert_contains 'plot_rows=3'
assert_contains 'max_plot_gap_seconds=60'
assert_contains 'last_plot_update=1970-01-01T00:18:10Z'
assert_contains 'last_new_path=1970-01-01T00:18:10Z'
assert_contains 'queue_discoveries_by_hour=0:3'
assert_contains '## Feedback Metrics'
assert_contains 'state_coverage_node_growth=2'
assert_contains 'edge_coverage_nonzero_cells=42'
assert_contains '## JaCoCo Coverage'
assert_contains 'line_covered_delta=12'
assert_contains 'classes_covered_by_campaign_not_baseline=3'
assert_contains 'line_details_dir=/tmp/line-details'
assert_contains 'baseline_line_locations_covered=10'
assert_contains 'campaign_line_locations_covered=14'
assert_contains 'line_locations_covered_by_campaign_not_baseline=6'
assert_contains 'line_locations_covered_by_baseline_not_campaign=2'
assert_contains 'line_location_coverage_delta=4'
assert_contains '## Hangs'
assert_contains 'unique_hangs=2'
assert_contains 'hang_analysis=available'
assert_contains 'unique_hang_hash_count=1'
assert_contains 'duplicate_hang_count=1'
assert_contains 'hang_replay_classification=available'
assert_contains 'replay_sample_count=2'
assert_contains 'replay_success_count=1'
assert_contains 'replay_timeout_count=0'
assert_contains 'replay_sigsegv_count=0'
assert_contains 'replay_no_response_exit_count=1'
assert_contains 'replay_response_sequence_count=1'
assert_contains 'replay_no_response_sequence_count=1'
assert_contains 'target_reachable_after_replay=yes'
if grep -Fq 'sample_1_file=' "$REPORT" || grep -Fq 'sample_1_log=' "$REPORT"; then
  echo "Report should not include per-sample hang replay details" >&2
  cat "$REPORT" >&2
  exit 1
fi
if grep -Fq 'hang_replay_interpretation=' "$REPORT"; then
  echo "Report should not include black-box hang replay interpretation" >&2
  cat "$REPORT" >&2
  exit 1
fi
assert_contains '## Caveats'
assert_contains 'JaCoCo coverage phase: whole-process'
assert_contains '## Artifact Index'

echo "PASS: campaign run report"
