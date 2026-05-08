#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <eval-run-dir> [baseline-jacoco-xml]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVAL_RUN_DIR="$1"
BASELINE_XML="${2:-}"
CAMPAIGN_DIR="$EVAL_RUN_DIR/campaign"
EVAL_SUMMARY="$EVAL_RUN_DIR/eval-summary.txt"
RECOVERED_SUMMARY="$CAMPAIGN_DIR/run-summary.txt"
RECOVERED_REPORT="$CAMPAIGN_DIR/campaign-report.md"
RECOVERED_COMPARISON="$CAMPAIGN_DIR/coverage/comparison-vs-latest-baseline.txt"
RECOVERED_COMPARISON_ALIAS="$CAMPAIGN_DIR/coverage/comparison-vs-baseline.txt"
LINE_DETAILS_DIR="$CAMPAIGN_DIR/coverage/line-details"
JACOCO_EXEC="$CAMPAIGN_DIR/logs/jacoco.exec"
JACOCO_REPORT_DIR="$CAMPAIGN_DIR/coverage"
JACOCO_XML="$JACOCO_REPORT_DIR/jacoco.xml"
JACOCO_HTML_DIR="$JACOCO_REPORT_DIR/html"
JACOCO_REPORT_LOG="$CAMPAIGN_DIR/logs/jacoco-report.log"
JACOCO_INIT="$CAMPAIGN_DIR/build/jacoco-campaign-report.recovered.init.gradle"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "missing required file: $path" >&2; exit 2; }
}

kv() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '$1 == k { print substr($0, length(k)+2); exit }' "$file"
}

stat_value() {
  local key="$1"
  local file="$CAMPAIGN_DIR/aflnet-out/fuzzer_stats"
  [[ -f "$file" ]] || return 0
  awk -F: -v k="$key" '$1 ~ "^" k "[[:space:]]*$" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' "$file"
}

count_files() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return; }
  find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' '
}

classify_aflnet_exit() {
  local code="$1"
  case "$code" in
    0) echo "clean" ;;
    124) echo "controlled-timeout" ;;
    130) echo "controlled-interrupt" ;;
    143) echo "controlled-sigterm" ;;
    139) echo "unexpected-sigsegv" ;;
    137) echo "unexpected-sigkill" ;;
    unavailable) echo "unavailable" ;;
    *) echo "unexpected-exit-$code" ;;
  esac
}

infer_feedback_type() {
  local mode="$1"
  case "$mode" in
    state-aware) echo "state-aware+code" ;;
    code-only) echo "code-only" ;;
    state-only) echo "state-only" ;;
    *) echo "unknown" ;;
  esac
}

infer_state_aware_enabled() {
  local mode="$1"
  case "$mode" in
    state-aware|state-only) echo "yes" ;;
    code-only) echo "no" ;;
    *) echo "unknown" ;;
  esac
}

generate_jacoco_campaign_report() {
  require_file "$JACOCO_EXEC"
  mkdir -p "$JACOCO_REPORT_DIR" "$JACOCO_HTML_DIR" "$CAMPAIGN_DIR/build"
  cat >"$JACOCO_INIT" <<'EOF'
import org.gradle.testing.jacoco.tasks.JacocoReport

allprojects { project ->
  project.plugins.apply('jacoco')
  project.jacoco.toolVersion = '0.8.14'
}

gradle.projectsEvaluated {
  def reportDir = new File(System.getProperty('jacocoReportDir'))
  def execFile = new File(System.getProperty('jacocoExecFile'))
  def javaProjects = rootProject.allprojects.findAll { project ->
    project.plugins.hasPlugin('java') && project.extensions.findByName('sourceSets') != null
  }
  def classTasks = javaProjects.collect { project -> project.tasks.named('classes') }

  rootProject.tasks.register('jacocoCampaignReport', JacocoReport) { reportTask ->
    reportTask.group = 'verification'
    reportTask.description = 'Generates aggregate JaCoCo report for recovered AFLNet campaign coverage.'
    reportTask.dependsOn(classTasks)
    reportTask.executionData.from(execFile)
    reportTask.sourceDirectories.from(javaProjects.collect { project -> project.sourceSets.main.allSource.srcDirs })
    reportTask.classDirectories.from(javaProjects.collect { project -> project.sourceSets.main.output.classesDirs })
    reportTask.reports { reports ->
      reports.xml.required = true
      reports.xml.outputLocation = new File(reportDir, 'jacoco.xml')
      reports.html.required = true
      reports.html.outputLocation = new File(reportDir, 'html')
      reports.csv.required = false
    }
  }
}
EOF
  local gradle_exit=0
  set +e
  (
    cd "$ROOT/velocity"
    ./gradlew jacocoCampaignReport \
      --offline \
      --no-daemon \
      --init-script "$JACOCO_INIT" \
      -DjacocoExecFile="$JACOCO_EXEC" \
      -DjacocoReportDir="$JACOCO_REPORT_DIR"
  ) >"$JACOCO_REPORT_LOG" 2>&1
  gradle_exit=$?
  set -e
  if [[ "$gradle_exit" -ne 0 ]]; then
    (
      cd "$ROOT/velocity"
      ./gradlew jacocoCampaignReport \
        --no-daemon \
        --init-script "$JACOCO_INIT" \
        -DjacocoExecFile="$JACOCO_EXEC" \
        -DjacocoReportDir="$JACOCO_REPORT_DIR"
    ) >>"$JACOCO_REPORT_LOG" 2>&1
  fi
  require_file "$JACOCO_XML"
}

require_file "$EVAL_SUMMARY"
require_file "$CAMPAIGN_DIR/aflnet-out/fuzzer_stats"
require_file "$CAMPAIGN_DIR/logs/velocity.log"
require_file "$CAMPAIGN_DIR/logs/flying-squid.log"
require_file "$CAMPAIGN_DIR/logs/aflnet.log"
require_file "$ROOT/scripts/classify-campaign-logs.sh"
require_file "$ROOT/scripts/extract-campaign-feedback-metrics.sh"
require_file "$ROOT/scripts/analyze-aflnet-hangs.sh"
require_file "$ROOT/scripts/summarize-campaign-run.sh"

FEEDBACK_MODE="$(kv "$EVAL_SUMMARY" aflnet_feedback_mode)"
CAMPAIGN_SECONDS="$(kv "$EVAL_SUMMARY" campaign_seconds)"
[[ -n "$FEEDBACK_MODE" ]] || FEEDBACK_MODE="state-aware"
[[ -n "$CAMPAIGN_SECONDS" ]] || CAMPAIGN_SECONDS="86400"

if [[ -z "$BASELINE_XML" ]]; then
  BASELINE_XML="$(kv "$EVAL_SUMMARY" baseline_xml)"
fi
if [[ "$BASELINE_XML" == /work/* ]]; then
  BASELINE_XML="$ROOT/${BASELINE_XML#/work/}"
fi

PROCESS_STATUS="missing"
if [[ -f "$CAMPAIGN_DIR/velocity.pid" ]]; then
  pid="$(cat "$CAMPAIGN_DIR/velocity.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    PROCESS_STATUS="alive"
  else
    PROCESS_STATUS="exited"
  fi
fi

CLASSIFICATION_SUMMARY="$(VELOCITY_PROCESS_STATUS="$PROCESS_STATUS" "$ROOT/scripts/classify-campaign-logs.sh" "$CAMPAIGN_DIR/logs/velocity.log" "$CAMPAIGN_DIR/logs/flying-squid.log" "$CAMPAIGN_DIR/logs/aflnet.log")"
FEEDBACK_METRICS_SUMMARY="$("$ROOT/scripts/extract-campaign-feedback-metrics.sh" "$CAMPAIGN_DIR")"
AGENT_ENGINE="$(grep -m1 '\[afl-mc-agent\] Engine:' "$CAMPAIGN_DIR/logs/velocity.log" | sed 's/^.*Engine: //' || true)"
[[ -n "$AGENT_ENGINE" ]] || AGENT_ENGINE="unknown"
STATE_PATHS="$(count_files "$CAMPAIGN_DIR/aflnet-out/replayable-new-ipsm-paths")"
if [[ "$STATE_PATHS" -gt 0 || -s "$CAMPAIGN_DIR/aflnet-out/ipsm.dot" ]]; then
  STATE_EVIDENCE="observable"
else
  STATE_EVIDENCE="none"
fi
if grep -q 'ShmCoverageEngine' "$CAMPAIGN_DIR/logs/velocity.log" 2>/dev/null; then
  EDGE_EVIDENCE="shm-attached"
elif grep -q '\[afl-mc-agent\] Agent ready' "$CAMPAIGN_DIR/logs/velocity.log" 2>/dev/null; then
  EDGE_EVIDENCE="agent-loaded-no-shm"
else
  EDGE_EVIDENCE="none"
fi

AFL_EXIT="$(cat "$CAMPAIGN_DIR/aflnet.exit" 2>/dev/null || echo unavailable)"
AFL_EXIT_CLASS="$(classify_aflnet_exit "$AFL_EXIT")"

{
  echo "campaign_status=FAIL"
  echo "recovery_status=posthoc-artifact-reconstruction"
  echo "recovery_reason=late-wrapper-failure-stale-file-handle"
  echo "run_dir=$CAMPAIGN_DIR"
  echo "campaign_role=recovered-coverage-reporting-run"
  echo "git_commit=unavailable"
  echo "git_dirty=unavailable"
  echo "target_backend=flying-squid"
  echo "velocity_config=$ROOT/velocity/velocity.toml"
  echo "campaign_seconds=$CAMPAIGN_SECONDS"
  echo "aflnet_protocol=MC"
  echo "aflnet_binary=$ROOT/aflnet/afl-fuzz"
  echo "aflnet_binary_mode=repo-built"
  echo "aflnet_local_smoke_workaround=0"
  echo "aflnet_startup_delay_usec=10000"
  echo "aflnet_poll_wait_ms=100"
  echo "aflnet_socket_timeout_usec=1000"
  echo "aflnet_exec_timeout_ms=1000+"
  echo "campaign_seed_glob=handshake-only.bin"
  echo "aflnet_feedback_mode=$FEEDBACK_MODE"
  echo "aflnet_state_aware_enabled=$(infer_state_aware_enabled "$FEEDBACK_MODE")"
  echo "aflnet_feedback_type=$(infer_feedback_type "$FEEDBACK_MODE")"
  if [[ "$FEEDBACK_MODE" == "state-only" ]]; then
    echo "afl_shm_id=disabled"
    echo "aflnet_reuse_shm_id=0"
  else
    echo "afl_shm_id=unavailable"
    echo "aflnet_reuse_shm_id=1"
  fi
  echo "jacoco_enabled=$( [[ -f "$JACOCO_EXEC" ]] && echo 1 || echo 0 )"
  echo "aflnet_stats_log=disabled"
  echo "aflnet_stats_log_interval=0"
  echo "aflnet_exit=$AFL_EXIT"
  echo "aflnet_exit_class=$AFL_EXIT_CLASS"
  echo "execs_done=$(stat_value execs_done)"
  echo "execs_per_sec=$(stat_value execs_per_sec)"
  echo "queue_count=$(count_files "$CAMPAIGN_DIR/aflnet-out/queue")"
  echo "crashes=$(count_files "$CAMPAIGN_DIR/aflnet-out/crashes")"
  echo "hangs=$(count_files "$CAMPAIGN_DIR/aflnet-out/hangs")"
  echo "replayable_crashes=$(count_files "$CAMPAIGN_DIR/aflnet-out/replayable-crashes")"
  echo "replayable_hangs=$(count_files "$CAMPAIGN_DIR/aflnet-out/replayable-hangs")"
  echo "state_feedback_evidence=$STATE_EVIDENCE"
  echo "state_path_artifacts=$STATE_PATHS"
  echo "edge_feedback_evidence=$EDGE_EVIDENCE"
  echo "agent_engine=$AGENT_ENGINE"
  printf '%s\n' "$FEEDBACK_METRICS_SUMMARY"
  printf '%s\n' "$CLASSIFICATION_SUMMARY"
  echo "velocity_alive_after_campaign=unavailable"
  echo "velocity_log=$CAMPAIGN_DIR/logs/velocity.log"
  echo "backend_log=$CAMPAIGN_DIR/logs/flying-squid.log"
  echo "aflnet_log=$CAMPAIGN_DIR/logs/aflnet.log"
  echo "edge_metrics_log=$CAMPAIGN_DIR/logs/edge-metrics.txt"
} > "$RECOVERED_SUMMARY"

if [[ -s "$JACOCO_EXEC" ]]; then
  generate_jacoco_campaign_report
  {
    echo "jacoco_enabled=1"
    echo "coverage_tool=jacoco"
    echo "coverage_role=human-readable-reporting"
    echo "jacoco_coverage_phase=whole-process"
    echo "jacoco_coverage_includes_startup=yes"
    echo "jacoco_coverage_includes_preflight=yes"
    echo "jacoco_coverage_includes_aflnet_campaign=yes"
    echo "jacoco_coverage_includes_teardown=unknown"
    echo "velocity_process_status_before_jacoco_teardown=unavailable"
    echo "velocity_terminated_for_jacoco_dump=unknown"
    echo "jacoco_exec=$JACOCO_EXEC"
    echo "jacoco_report_xml=$JACOCO_XML"
    echo "jacoco_report_html=$JACOCO_HTML_DIR"
    echo "jacoco_report_log=$JACOCO_REPORT_LOG"
  } >> "$RECOVERED_SUMMARY"
  if [[ -n "$BASELINE_XML" && -f "$BASELINE_XML" ]]; then
    mkdir -p "$LINE_DETAILS_DIR"
    "$ROOT/scripts/compare-jacoco-coverage.sh" --details-dir "$LINE_DETAILS_DIR" "$BASELINE_XML" "$JACOCO_XML" > "$RECOVERED_COMPARISON"
    cp "$RECOVERED_COMPARISON" "$RECOVERED_COMPARISON_ALIAS"
  fi
fi

"$ROOT/scripts/analyze-aflnet-hangs.sh" "$CAMPAIGN_DIR" >/dev/null
"$ROOT/scripts/summarize-campaign-run.sh" "$CAMPAIGN_DIR" >/dev/null

echo "RECOVERED_SUMMARY=$RECOVERED_SUMMARY"
echo "RECOVERED_REPORT=$RECOVERED_REPORT"
if [[ -f "$RECOVERED_COMPARISON" ]]; then echo "RECOVERED_COMPARISON=$RECOVERED_COMPARISON"; fi
