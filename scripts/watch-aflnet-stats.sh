#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--once] <campaign-run-dir> [interval-seconds]" >&2
}

ONCE=0
if [[ "${1:-}" == "--once" ]]; then
  ONCE=1
  shift
fi

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
RUN_DIR="$1"
INTERVAL="${2:-1}"
AFL_OUT="$RUN_DIR/aflnet-out"
STATS="$AFL_OUT/fuzzer_stats"
PLOT="$AFL_OUT/plot_data"

stat_value() {
  local key="$1"
  [[ -f "$STATS" ]] || { echo unavailable; return; }
  awk -F: -v k="$key" '$1 ~ "^" k "[[:space:]]*$" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; found=1; exit } END { if (!found) print "unavailable" }' "$STATS"
}

plot_nodes_edges() {
  [[ -f "$PLOT" ]] || { echo "unavailable unavailable"; return; }
  awk -F, '
    /^[[:space:]]*#/ { next }
    NF >= 13 {
      nodes=$12
      edges=$13
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", nodes)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", edges)
    }
    END {
      if (nodes != "" && edges != "") print nodes " " edges
      else print "unavailable unavailable"
    }
  ' "$PLOT"
}

print_once() {
  local execs_done execs_per_sec paths_total paths_found bitmap_cvg crashes hangs nodes edges
  execs_done="$(stat_value execs_done)"
  execs_per_sec="$(stat_value execs_per_sec)"
  paths_total="$(stat_value paths_total)"
  paths_found="$(stat_value paths_found)"
  bitmap_cvg="$(stat_value bitmap_cvg)"
  crashes="$(stat_value unique_crashes)"
  hangs="$(stat_value unique_hangs)"
  read -r nodes edges <<<"$(plot_nodes_edges)"
  echo "[aflnet-stats] execs_done=$execs_done execs_per_sec=$execs_per_sec paths_total=$paths_total paths_found=$paths_found bitmap_cvg=$bitmap_cvg n_nodes=$nodes n_edges=$edges crashes=$crashes hangs=$hangs"
}

if [[ "$ONCE" == "1" ]]; then
  print_once
  exit 0
fi

while true; do
  print_once
  sleep "$INTERVAL"
done
