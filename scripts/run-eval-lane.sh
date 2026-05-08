#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AFLNET_FEEDBACK_MODE="${AFLNET_FEEDBACK_MODE:-state-aware}"
CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-600}"
RUN_BASELINE="${RUN_BASELINE:-1}"
BASELINE_XML="${BASELINE_XML:-}"
EVAL_RUN_ROOT="${EVAL_RUN_ROOT:-$ROOT/eval-runs}"
EVAL_RUN_ID="${EVAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$AFLNET_FEEDBACK_MODE}"
EVAL_RUN_DIR="${EVAL_RUN_DIR:-$EVAL_RUN_ROOT/$EVAL_RUN_ID}"
BASELINE_RUN_DIR="$EVAL_RUN_DIR/velocity-jacoco-baseline"
CAMPAIGN_RUN_DIR="$EVAL_RUN_DIR/campaign"
EVAL_SUMMARY="$EVAL_RUN_DIR/eval-summary.txt"
EVAL_METADATA="$EVAL_RUN_DIR/eval-metadata.txt"
BASELINE_STDOUT="$EVAL_RUN_DIR/velocity-jacoco-baseline.stdout.txt"
CAMPAIGN_STDOUT="$EVAL_RUN_DIR/aflnet-campaign.stdout.txt"
COMPARISON_OUT="$CAMPAIGN_RUN_DIR/coverage/comparison-vs-latest-baseline.txt"
COMPARISON_ALIAS="$CAMPAIGN_RUN_DIR/coverage/comparison-vs-baseline.txt"
LINE_DETAILS_DIR="$CAMPAIGN_RUN_DIR/coverage/line-details"
HANG_ANALYSIS_OUT="$CAMPAIGN_RUN_DIR/hang-analysis.txt"
CAMPAIGN_REPORT="$CAMPAIGN_RUN_DIR/campaign-report.md"
CAMPAIGN_SUMMARY="$CAMPAIGN_RUN_DIR/run-summary.txt"

mkdir -p "$EVAL_RUN_DIR"

fail() {
  local message="$1"
  {
    echo "eval_status=FAIL"
    echo "reason=$message"
    echo "eval_run_dir=$EVAL_RUN_DIR"
    echo "aflnet_feedback_mode=$AFLNET_FEEDBACK_MODE"
    echo "campaign_seconds=$CAMPAIGN_SECONDS"
    echo "run_baseline=$RUN_BASELINE"
    echo "baseline_run_dir=$BASELINE_RUN_DIR"
    echo "campaign_run_dir=$CAMPAIGN_RUN_DIR"
    echo "campaign_summary=$CAMPAIGN_SUMMARY"
    echo "campaign_report=$CAMPAIGN_REPORT"
  } >"$EVAL_SUMMARY" 2>/dev/null || true
  echo "FAIL: $message" >&2
  echo "EVAL_RUN_DIR=$EVAL_RUN_DIR" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing-required-file:$path"
}

validate_mode() {
  case "$AFLNET_FEEDBACK_MODE" in
    state-aware|code-only|state-only) ;;
    *) fail "unsupported-feedback-mode:$AFLNET_FEEDBACK_MODE" ;;
  esac
}

capture_metadata() {
  {
    echo "captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname=$(hostname)"
    echo "root=$ROOT"
    echo "eval_run_dir=$EVAL_RUN_DIR"
    echo "aflnet_feedback_mode=$AFLNET_FEEDBACK_MODE"
    echo "campaign_seconds=$CAMPAIGN_SECONDS"
    echo "run_baseline=$RUN_BASELINE"
    echo "slurm_job_id=${SLURM_JOB_ID:-unavailable}"
    echo "slurm_job_name=${SLURM_JOB_NAME:-unavailable}"
    echo "slurm_job_partition=${SLURM_JOB_PARTITION:-unavailable}"
    echo "slurm_job_nodelist=${SLURM_JOB_NODELIST:-unavailable}"
    echo "slurm_cpus_per_task=${SLURM_CPUS_PER_TASK:-unavailable}"
    echo "slurm_job_cpus_per_node=${SLURM_JOB_CPUS_PER_NODE:-unavailable}"
    echo "slurm_mem_per_node=${SLURM_MEM_PER_NODE:-unavailable}"
    echo "slurm_mem_per_cpu=${SLURM_MEM_PER_CPU:-unavailable}"
    echo "slurm_submit_dir=${SLURM_SUBMIT_DIR:-unavailable}"
    lscpu | sed 's/^/lscpu:/'
    free -h | sed 's/^/free:/'
  } >"$EVAL_METADATA"
}

validate_mode
capture_metadata
require_file "$ROOT/scripts/test-velocity-jacoco-baseline.sh"
require_file "$ROOT/scripts/run-aflnet-campaign-smoke.sh"
require_file "$ROOT/scripts/compare-jacoco-coverage.sh"
require_file "$ROOT/scripts/analyze-aflnet-hangs.sh"
require_file "$ROOT/scripts/summarize-campaign-run.sh"

if [[ "$RUN_BASELINE" == "1" ]]; then
  JACOCO_BASELINE_RUN_DIR="$BASELINE_RUN_DIR" "$ROOT/scripts/test-velocity-jacoco-baseline.sh" >"$BASELINE_STDOUT" 2>&1 \
    || { cat "$BASELINE_STDOUT" >&2 || true; fail "velocity-jacoco-baseline-failed"; }
  BASELINE_XML="$BASELINE_RUN_DIR/jacoco.xml"
else
  [[ -n "$BASELINE_XML" ]] || fail "baseline-xml-required-when-run_baseline=0"
fi

require_file "$BASELINE_XML"

ENABLE_JACOCO=1 \
AFLNET_FEEDBACK_MODE="$AFLNET_FEEDBACK_MODE" \
CAMPAIGN_SECONDS="$CAMPAIGN_SECONDS" \
CAMPAIGN_RUN_DIR="$CAMPAIGN_RUN_DIR" \
  "$ROOT/scripts/run-aflnet-campaign-smoke.sh" >"$CAMPAIGN_STDOUT" 2>&1 \
  || { cat "$CAMPAIGN_STDOUT" >&2 || true; fail "aflnet-campaign-failed"; }

require_file "$CAMPAIGN_SUMMARY"
CAMPAIGN_XML="$(awk -F= '$1 == "jacoco_report_xml" { print substr($0, length($1) + 2); exit }' "$CAMPAIGN_SUMMARY")"
[[ -n "$CAMPAIGN_XML" ]] || fail "campaign-jacoco-xml-missing-from-summary"
require_file "$CAMPAIGN_XML"
mkdir -p "$LINE_DETAILS_DIR"
"$ROOT/scripts/compare-jacoco-coverage.sh" --details-dir "$LINE_DETAILS_DIR" "$BASELINE_XML" "$CAMPAIGN_XML" >"$COMPARISON_OUT" \
  || fail "jacoco-coverage-comparison-failed"
cp "$COMPARISON_OUT" "$COMPARISON_ALIAS"
"$ROOT/scripts/analyze-aflnet-hangs.sh" "$CAMPAIGN_RUN_DIR" >/dev/null \
  || fail "hang-analysis-failed"
"$ROOT/scripts/summarize-campaign-run.sh" "$CAMPAIGN_RUN_DIR" >/dev/null \
  || fail "campaign-summary-report-failed"

[[ -s "$COMPARISON_OUT" ]] || fail "comparison-output-missing"
[[ -s "$HANG_ANALYSIS_OUT" ]] || fail "hang-analysis-output-missing"
[[ -s "$CAMPAIGN_REPORT" ]] || fail "campaign-report-missing"

{
  echo "eval_status=PASS"
  echo "eval_run_dir=$EVAL_RUN_DIR"
  echo "eval_metadata=$EVAL_METADATA"
  echo "aflnet_feedback_mode=$AFLNET_FEEDBACK_MODE"
  echo "campaign_seconds=$CAMPAIGN_SECONDS"
  echo "run_baseline=$RUN_BASELINE"
  echo "baseline_run_dir=$BASELINE_RUN_DIR"
  echo "baseline_xml=$BASELINE_XML"
  echo "baseline_stdout=$BASELINE_STDOUT"
  echo "campaign_run_dir=$CAMPAIGN_RUN_DIR"
  echo "campaign_summary=$CAMPAIGN_SUMMARY"
  echo "campaign_stdout=$CAMPAIGN_STDOUT"
  echo "campaign_report=$CAMPAIGN_REPORT"
  echo "coverage_comparison=$COMPARISON_OUT"
  echo "coverage_comparison_alias=$COMPARISON_ALIAS"
  echo "hang_analysis=$HANG_ANALYSIS_OUT"
  echo "line_details_dir=$LINE_DETAILS_DIR"
} >"$EVAL_SUMMARY"

echo "EVAL_RUN_DIR=$EVAL_RUN_DIR"
echo "EVAL_SUMMARY=$EVAL_SUMMARY"
echo "BASELINE_XML=$BASELINE_XML"
echo "CAMPAIGN_RUN_DIR=$CAMPAIGN_RUN_DIR"
echo "CAMPAIGN_REPORT=$CAMPAIGN_REPORT"
echo "PASS: evaluation lane"
