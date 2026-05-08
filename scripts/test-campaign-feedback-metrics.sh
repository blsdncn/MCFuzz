#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RUN_DIR="$TMPDIR/fixture-run"
AFL_OUT="$RUN_DIR/aflnet-out"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$AFL_OUT/replayable-new-ipsm-paths" "$LOG_DIR"

cat >"$AFL_OUT/fuzzer_stats" <<'STATS'
execs_done        : 53
execs_per_sec     : 2.32
paths_total       : 2
paths_found       : 1
bitmap_cvg        : 1.83%
unique_crashes    : 0
unique_hangs      : 0
STATS

cat >"$AFL_OUT/plot_data" <<'PLOT'
# unix_time, cycles_done, cur_path, paths_total, pending_total, pending_favs, map_size, unique_crashes, unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges
1777433880, 0, 0, 1, 1, 0, 1.00%, 0, 0, 1, 1.00, 2, 1
1777433890, 0, 0, 2, 2, 0, 1.83%, 0, 0, 2, 2.32, 3, 2
PLOT

: >"$AFL_OUT/replayable-new-ipsm-paths/id:0-1-2:id:000000,orig:handshake-only.bin"

python3 - "$AFL_OUT/fuzz_bitmap" <<'PY'
from pathlib import Path
import sys
bitmap = bytearray([0xff]) * 65536
bitmap[0] = 0xfe
bitmap[123] = 0x7f
bitmap[65535] = 0x00
Path(sys.argv[1]).write_bytes(bitmap)
PY

cat >"$LOG_DIR/edge-metrics.txt" <<'EDGE'
edge_coverage_metric_status=available
edge_coverage_metric_source=javaagent-edge-metrics
edge_coverage_total_cells=65536
edge_coverage_nonzero_cells=12
edge_coverage_hit_count=345
edge_coverage_density_percent=0.0183
EDGE

OUT="$TMPDIR/metrics.out"
"$ROOT/scripts/extract-campaign-feedback-metrics.sh" "$RUN_DIR" >"$OUT"

assert_field() {
  local key="$1"
  local expected="$2"
  grep -qx "$key=$expected" "$OUT" || {
    echo "Expected $key=$expected" >&2
    cat "$OUT" >&2
    exit 1
  }
}

assert_field state_coverage_metric_status available
assert_field state_coverage_nodes 3
assert_field state_coverage_edges 2
assert_field state_coverage_initial_nodes 2
assert_field state_coverage_final_nodes 3
assert_field state_coverage_node_growth 1
assert_field state_coverage_initial_edges 1
assert_field state_coverage_final_edges 2
assert_field state_coverage_edge_growth 1
assert_field state_coverage_new_paths 1
assert_field afl_bitmap_metric_status available
assert_field afl_bitmap_cvg_percent 1.83
assert_field afl_bitmap_nonzero_cells unavailable
assert_field afl_bitmap_nonzero_cells_reason fuzz_bitmap_is_virgin_map_not_trace_bitmap
assert_field afl_fuzz_bitmap_changed_cells 3
assert_field afl_fuzz_bitmap_size 65536
assert_field queue_paths_total 2
assert_field queue_paths_found 1
assert_field edge_coverage_metric_status available
assert_field edge_coverage_metric_source javaagent-edge-metrics
assert_field edge_coverage_total_cells 65536
assert_field edge_coverage_nonzero_cells 12
assert_field edge_coverage_hit_count 345
assert_field edge_coverage_density_percent 0.0183

# Diagnostics and findings are summarized elsewhere; this extractor should not
# turn log classification into guidance feedback or duplicate crash/hang fields.
if grep -Eq '^(target_failure_class|velocity_fatal_exception_count|handled_client_exception_count|crashes|hangs)=' "$OUT"; then
  echo "Metric extractor emitted diagnostics/findings fields" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "PASS: campaign feedback metrics"
