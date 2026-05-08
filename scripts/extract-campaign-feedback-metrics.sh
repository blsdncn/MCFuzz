#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <campaign-run-dir>" >&2
  exit 2
fi

RUN_DIR="$1"
AFL_OUT="$RUN_DIR/aflnet-out"

if [[ ! -d "$AFL_OUT" ]]; then
  echo "missing AFLNet output directory: $AFL_OUT" >&2
  exit 2
fi

stat_value() {
  local key="$1"
  local file="$AFL_OUT/fuzzer_stats"
  [[ -f "$file" ]] || return 0
  awk -F: -v k="$key" '$1 ~ "^" k "[[:space:]]*$" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' "$file"
}

count_files() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return; }
  find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' '
}

plot_state_counts() {
  local file="$AFL_OUT/plot_data"
  [[ -f "$file" ]] || return 1
  awk -F, '
    /^[[:space:]]*#/ { next }
    NF >= 13 {
      nodes=$12
      edges=$13
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", nodes)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", edges)
      if (initial_nodes == "") {
        initial_nodes=nodes
        initial_edges=edges
      }
      final_nodes=nodes
      final_edges=edges
    }
    END {
      if (initial_nodes != "" && initial_edges != "" && final_nodes != "" && final_edges != "") {
        print initial_nodes " " initial_edges " " final_nodes " " final_edges
      } else {
        exit 1
      }
    }
  ' "$file"
}

fuzz_bitmap_changed_cells() {
  local file="$AFL_OUT/fuzz_bitmap"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
from pathlib import Path
import sys
# AFL's saved fuzz_bitmap artifact is a virgin map, not the live trace bitmap:
# unchanged cells are 0xff and discovered/changed cells differ from 0xff.
blob = Path(sys.argv[1]).read_bytes()
print(sum(1 for byte in blob if byte != 0xff))
PY
}

fuzz_bitmap_size() {
  local file="$AFL_OUT/fuzz_bitmap"
  [[ -f "$file" ]] || return 1
  wc -c <"$file" | tr -d ' '
}

bitmap_cvg="$(stat_value bitmap_cvg || true)"
bitmap_cvg="${bitmap_cvg%%%}"
paths_total="$(stat_value paths_total || true)"
paths_found="$(stat_value paths_found || true)"
state_new_paths="$(count_files "$AFL_OUT/replayable-new-ipsm-paths")"

if state_counts="$(plot_state_counts 2>/dev/null)"; then
  read -r initial_nodes initial_edges final_nodes final_edges <<<"$state_counts"
  echo "state_coverage_metric_status=available"
  echo "state_coverage_nodes=$final_nodes"
  echo "state_coverage_edges=$final_edges"
  echo "state_coverage_initial_nodes=$initial_nodes"
  echo "state_coverage_final_nodes=$final_nodes"
  echo "state_coverage_node_growth=$((final_nodes - initial_nodes))"
  echo "state_coverage_initial_edges=$initial_edges"
  echo "state_coverage_final_edges=$final_edges"
  echo "state_coverage_edge_growth=$((final_edges - initial_edges))"
else
  echo "state_coverage_metric_status=unavailable"
  echo "state_coverage_metric_reason=missing-plot-data-state-columns"
  echo "state_coverage_metric_required_artifact=plot_data-with-n_nodes-and-n_edges"
  echo "state_coverage_nodes=unavailable"
  echo "state_coverage_edges=unavailable"
  echo "state_coverage_initial_nodes=unavailable"
  echo "state_coverage_final_nodes=unavailable"
  echo "state_coverage_node_growth=unavailable"
  echo "state_coverage_initial_edges=unavailable"
  echo "state_coverage_final_edges=unavailable"
  echo "state_coverage_edge_growth=unavailable"
fi

echo "state_coverage_new_paths=$state_new_paths"

echo "afl_bitmap_metric_status=$([[ -n "$bitmap_cvg" || -f "$AFL_OUT/fuzz_bitmap" ]] && echo available || echo unavailable)"
echo "afl_bitmap_cvg_percent=${bitmap_cvg:-unavailable}"
echo "afl_bitmap_nonzero_cells=unavailable"
echo "afl_bitmap_nonzero_cells_reason=fuzz_bitmap_is_virgin_map_not_trace_bitmap"
if changed="$(fuzz_bitmap_changed_cells 2>/dev/null)"; then
  echo "afl_fuzz_bitmap_changed_cells=$changed"
  echo "afl_fuzz_bitmap_size=$(fuzz_bitmap_size)"
else
  echo "afl_fuzz_bitmap_changed_cells=unavailable"
  echo "afl_fuzz_bitmap_size=unavailable"
fi

echo "queue_paths_total=${paths_total:-unavailable}"
echo "queue_paths_found=${paths_found:-unavailable}"

edge_metrics_file="$RUN_DIR/logs/edge-metrics.txt"
if [[ -s "$edge_metrics_file" ]]; then
  grep -E '^edge_coverage_[A-Za-z0-9_]+=.*$' "$edge_metrics_file"
else
  # The current campaign shares the AFL bitmap between AFLNet and the Java agent.
  # That proves the edge feedback channel can attach, but it does not isolate Java
  # edge coverage from other AFLNet bitmap activity. Report this honestly instead
  # of pretending aggregate bitmap observations are Java-edge coverage metrics.
  echo "edge_coverage_metric_status=unavailable"
  echo "edge_coverage_metric_reason=shared_bitmap_not_edge_isolated"
  echo "edge_coverage_metric_required_artifact=edge-isolated-bitmap-or-per-engine-edge-counter"
fi
