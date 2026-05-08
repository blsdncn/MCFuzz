#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-120}"
AFLNET_STARTUP_DELAY_USEC="${AFLNET_STARTUP_DELAY_USEC:-10000}"
AFLNET_POLL_WAIT_MS="${AFLNET_POLL_WAIT_MS:-100}"
AFLNET_SOCKET_TIMEOUT_USEC="${AFLNET_SOCKET_TIMEOUT_USEC:-1000}"
AFLNET_EXEC_TIMEOUT_MS="${AFLNET_EXEC_TIMEOUT_MS:-1000+}"
CAMPAIGN_SEED_GLOB="${CAMPAIGN_SEED_GLOB:-handshake-only.bin}"
AFL_INCLUDE="${AFL_INCLUDE:-com.velocitypowered.*}"
AFL_EXCLUDE="${AFL_EXCLUDE:-com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket}"
AFL_SHM_ID="${AFL_SHM_ID:-}"
RESUME="${RESUME:-0}"
CAMPAIGN_RUN_ROOT="${CAMPAIGN_RUN_ROOT:-$ROOT/campaign-runs}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_DIR="${CAMPAIGN_RUN_DIR:-$CAMPAIGN_RUN_ROOT/$RUN_ID}"
AFL_OUT="$RUN_DIR/aflnet-out"
LOG_DIR="$RUN_DIR/logs"
BUILD_DIR="$RUN_DIR/build"
INPUT_DIR="$RUN_DIR/input-corpus"
SUMMARY="$RUN_DIR/run-summary.txt"
VELOCITY_LOG="$LOG_DIR/velocity.log"
SQUID_LOG="$LOG_DIR/flying-squid.log"
AFLNET_LOG="$LOG_DIR/aflnet.log"
AGENT_LOG="$LOG_DIR/agent.log"
EDGE_METRICS_LOG="$LOG_DIR/edge-metrics.txt"
BUILD_LOG="$LOG_DIR/build-aflnet.log"
CONNECTION_LOG="$LOG_DIR/preflight-connection.log"
AFLNET_USE_LOCAL_SMOKE_BINARY="${AFLNET_USE_LOCAL_SMOKE_BINARY:-0}"
ENABLE_JACOCO="${ENABLE_JACOCO:-0}"
AFLNET_FEEDBACK_MODE="${AFLNET_FEEDBACK_MODE:-state-aware}"
AFLNET_STATS_LOG_INTERVAL="${AFLNET_STATS_LOG_INTERVAL:-0}"
WATCH_STATS_LOG="$LOG_DIR/watch-stats.log"
JACOCO_WINDOW_MODE="${JACOCO_WINDOW_MODE:-whole-process}"
JACOCO_TCP_ADDRESS="${JACOCO_TCP_ADDRESS:-127.0.0.1}"
JACOCO_TCP_PORT="${JACOCO_TCP_PORT:-6300}"
JACOCO_AGENT_OUTER_JAR="${JACOCO_AGENT_JAR:-}"
JACOCO_AGENT_EXTRACTED="$BUILD_DIR/jacocoagent.jar"
JACOCO_CLI_JAR="${JACOCO_CLI_JAR:-}"
JACOCO_STARTUP_EXEC="$LOG_DIR/jacoco-startup-preflight.exec"
JACOCO_EXEC="$LOG_DIR/jacoco.exec"
if [[ "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
  JACOCO_EXEC="$LOG_DIR/jacoco-campaign.exec"
fi
JACOCO_REPORT_DIR="$RUN_DIR/coverage"
JACOCO_XML="$JACOCO_REPORT_DIR/jacoco.xml"
JACOCO_HTML_DIR="$JACOCO_REPORT_DIR/html"
JACOCO_REPORT_LOG="$LOG_DIR/jacoco-report.log"
JACOCO_REPORT_INIT_SCRIPT="$BUILD_DIR/jacoco-campaign-report.init.gradle"
REPO_AFLNET_BIN="$ROOT/aflnet/afl-fuzz"
AFLNET_BIN="${AFLNET_BIN:-$REPO_AFLNET_BIN}"
AFLNET_BINARY_MODE="repo-built"
if [[ "$AFLNET_USE_LOCAL_SMOKE_BINARY" == "1" ]]; then
  AFLNET_BIN="$BUILD_DIR/afl-fuzz-mc-smoke"
  AFLNET_BINARY_MODE="local-generated"
elif [[ "$AFLNET_BIN" != "$REPO_AFLNET_BIN" ]]; then
  AFLNET_BINARY_MODE="custom"
fi

mkdir -p "$RUN_DIR" "$LOG_DIR" "$BUILD_DIR" "$INPUT_DIR"

pidfiles=()
watch_stats_pid=""
created_shm_id=""
cleanup() {
  if [[ -n "$watch_stats_pid" ]]; then
    kill "$watch_stats_pid" 2>/dev/null || true
    wait "$watch_stats_pid" 2>/dev/null || true
  fi
  local pid
  for pidfile in "${pidfiles[@]:-}"; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    if [[ -n "$pid" ]]; then
      kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.5
  for pidfile in "${pidfiles[@]:-}"; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    if [[ -n "$pid" ]]; then
      kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$created_shm_id" ]]; then
    ipcrm -m "$created_shm_id" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing required file: $path" >&2; exit 2; }
}

port_pids() {
  local port="$1"
  lsof -ti tcp:"$port" 2>/dev/null || true
}

require_port_free() {
  local port="$1"
  local pids
  pids="$(port_pids "$port")"
  [[ -z "$pids" ]] || { echo "Required port $port is already in use by PID(s): $pids" >&2; exit 3; }
}

wait_for_port() {
  local port="$1"
  local attempts="${2:-75}"
  for _ in $(seq 1 "$attempts"); do
    if ss -tln | grep -q ":$port "; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

is_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

ensure_campaign_shm() {
  if [[ -n "$AFL_SHM_ID" ]]; then
    return 0
  fi
  command -v ipcmk >/dev/null || { echo "ipcmk is required to create campaign SHM" >&2; exit 7; }
  command -v ipcrm >/dev/null || { echo "ipcrm is required to clean campaign SHM" >&2; exit 7; }
  AFL_SHM_ID="$(ipcmk -M 65536 | awk '{print $NF}')"
  [[ "$AFL_SHM_ID" =~ ^[0-9]+$ ]] || { echo "Failed to create campaign SHM" >&2; exit 7; }
  created_shm_id="$AFL_SHM_ID"
}

write_compat_headers() {
  mkdir -p "$BUILD_DIR/compat/graphviz" "$BUILD_DIR/compat/sys"
  cat > "$BUILD_DIR/compat/graphviz/gvc.h" <<'EOF'
#ifndef AFLNET_COMPAT_GRAPHVIZ_GVC_H
#define AFLNET_COMPAT_GRAPHVIZ_GVC_H
#include <stdio.h>
#include <stdlib.h>
#define Agdirected 1
#define AGNODE 1
#define AGEDGE 2
#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif
typedef struct Agraph_t { int dummy; } Agraph_t;
typedef struct Agnode_t { int dummy; } Agnode_t;
typedef struct Agedge_t { int dummy; } Agedge_t;
static inline Agraph_t *agopen(char *name, int kind, void *disc) { (void)name; (void)kind; (void)disc; return (Agraph_t*)calloc(1, sizeof(Agraph_t)); }
static inline int agattr(Agraph_t *g, int kind, char *name, char *value) { (void)g; (void)kind; (void)name; (void)value; return 0; }
static inline int agclose(Agraph_t *g) { free(g); return 0; }
static inline Agnode_t *agnode(Agraph_t *g, char *name, int create) { (void)g; (void)name; if (!create) return NULL; return (Agnode_t*)calloc(1, sizeof(Agnode_t)); }
static inline Agedge_t *agedge(Agraph_t *g, Agnode_t *t, Agnode_t *h, char *name, int create) { (void)g; (void)t; (void)h; (void)name; if (!create) return NULL; return (Agedge_t*)calloc(1, sizeof(Agedge_t)); }
static inline int agset(void *obj, char *name, char *value) { (void)obj; (void)name; (void)value; return 0; }
static inline int agwrite(Agraph_t *g, FILE *fp) { (void)g; if (fp) fputs("digraph g {\n}\n", fp); return 0; }
static inline int agnnodes(Agraph_t *g) { (void)g; return 0; }
static inline int agnedges(Agraph_t *g) { (void)g; return 0; }
#endif
EOF
  cat > "$BUILD_DIR/compat/sys/capability.h" <<'EOF'
#ifndef AFLNET_COMPAT_SYS_CAPABILITY_H
#define AFLNET_COMPAT_SYS_CAPABILITY_H
#define CAP_SYS_ADMIN 21
#define CAP_EFFECTIVE 0
#define CAP_PERMITTED 1
#define CAP_SET 1
typedef int cap_value_t;
typedef void* cap_t;
typedef int cap_flag_t;
typedef int cap_flag_value_t;
static inline cap_t cap_get_file(const char *filename) { (void)filename; return (cap_t)0; }
static inline cap_t cap_get_proc(void) { return (cap_t)0; }
static inline int cap_get_flag(cap_t cap, cap_value_t value, cap_flag_t flag, cap_flag_value_t *result) { (void)cap; (void)value; (void)flag; if (result) *result = 0; return 0; }
static inline int cap_free(void *obj) { (void)obj; return 0; }
#endif
EOF
}

build_local_smoke_aflnet() {
  write_compat_headers
  cp "$ROOT/aflnet/afl-fuzz.c" "$BUILD_DIR/afl-fuzz-smoke.c"
  python3 - "$BUILD_DIR/afl-fuzz-smoke.c" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '''  //give the server a bit more time to gracefully terminate
  while(1) {
    int status = kill(child_pid, 0);
    if ((status != 0) && (errno == ESRCH)) break;
  }
'''
new = '''  // Smoke build note: do not spin on kill(child_pid, 0) here.
  // The child may be a zombie until run_target() performs waitpid() immediately
  // after send_over_network() returns.
'''
if old in text:
    text = text.replace(old, new, 1)
path.write_text(text)
PY
  (
    cd "$ROOT/aflnet"
    gcc -O3 -funroll-loops -Wall -D_FORTIFY_SOURCE=2 -g \
      -Wno-pointer-sign -Wno-unused-result \
      -I"$BUILD_DIR/compat" -I"$ROOT/aflnet" \
      -DAFL_PATH='"."' -DDOC_PATH='"."' -DBIN_PATH='"."' \
      "$BUILD_DIR/afl-fuzz-smoke.c" aflnet.c -o "$AFLNET_BIN" -ldl -lm
  ) >"$BUILD_LOG" 2>&1 || {
    echo "AFLNet build failed; see $BUILD_LOG" >&2
    exit 4
  }
}

copy_seed_corpus() {
  find "$ROOT/seeds" -maxdepth 1 -type f -name "$CAMPAIGN_SEED_GLOB" ! -name '*-replay.bin' -print0 \
    | while IFS= read -r -d '' seed; do cp "$seed" "$INPUT_DIR/"; done
  local count
  count="$(find "$INPUT_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  [[ "$count" -gt 0 ]] || { echo "No raw MC seeds copied into $INPUT_DIR" >&2; exit 5; }
}

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

prepare_jacoco_agent() {
  [[ "$ENABLE_JACOCO" == "1" ]] || return 0
  require_file "$ROOT/scripts/resolve-jacoco-outer-jar.sh"
  JACOCO_AGENT_OUTER_JAR="$("$ROOT/scripts/resolve-jacoco-outer-jar.sh" "$JACOCO_AGENT_OUTER_JAR")"
  require_file "$JACOCO_AGENT_OUTER_JAR"
  unzip -p "$JACOCO_AGENT_OUTER_JAR" jacocoagent.jar >"$JACOCO_AGENT_EXTRACTED"
  [[ -s "$JACOCO_AGENT_EXTRACTED" ]] || { echo "Failed to extract jacocoagent.jar" >&2; exit 8; }
  if [[ "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
    require_file "$ROOT/scripts/resolve-jacoco-cli-jar.sh"
    JACOCO_CLI_JAR="$("$ROOT/scripts/resolve-jacoco-cli-jar.sh" "$JACOCO_CLI_JAR")"
    require_file "$JACOCO_CLI_JAR"
  fi
}

dump_jacoco_exec() {
  local destfile="$1"
  local reset_flag="${2:-0}"
  [[ "$ENABLE_JACOCO" == "1" ]] || return 0
  [[ "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]] || return 0
  [[ -n "$JACOCO_CLI_JAR" ]] || { echo "JaCoCo CLI jar missing for campaign-epoch dump" >&2; return 1; }
  local cmd=(
    java -jar "$JACOCO_CLI_JAR" dump
    --address "$JACOCO_TCP_ADDRESS"
    --port "$JACOCO_TCP_PORT"
    --retry 20
    --destfile "$destfile"
    --quiet
  )
  if [[ "$reset_flag" == "1" ]]; then
    cmd+=(--reset)
  fi
  "${cmd[@]}"
}

generate_jacoco_campaign_report() {
  [[ "$ENABLE_JACOCO" == "1" ]] || return 0
  [[ -s "$JACOCO_EXEC" ]] || { echo "JaCoCo exec missing: $JACOCO_EXEC" >&2; return 1; }
  mkdir -p "$JACOCO_REPORT_DIR" "$JACOCO_HTML_DIR"
  cat >"$JACOCO_REPORT_INIT_SCRIPT" <<'EOF'
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
    reportTask.description = 'Generates aggregate JaCoCo report for AFLNet campaign coverage.'
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
      --init-script "$JACOCO_REPORT_INIT_SCRIPT" \
      -DjacocoExecFile="$JACOCO_EXEC" \
      -DjacocoReportDir="$JACOCO_REPORT_DIR"
  ) >"$JACOCO_REPORT_LOG" 2>&1
  gradle_exit=$?
  set -e
  if [[ "$gradle_exit" -eq 0 ]]; then
    return 0
  fi
  echo "Offline JaCoCo campaign report failed; retrying online" >>"$JACOCO_REPORT_LOG"
  (
    cd "$ROOT/velocity"
    ./gradlew jacocoCampaignReport \
      --no-daemon \
      --init-script "$JACOCO_REPORT_INIT_SCRIPT" \
      -DjacocoExecFile="$JACOCO_EXEC" \
      -DjacocoReportDir="$JACOCO_REPORT_DIR"
  ) >>"$JACOCO_REPORT_LOG" 2>&1
}

stop_velocity_for_jacoco_dump() {
  [[ "$ENABLE_JACOCO" == "1" ]] || return 0
  local pid
  pid="$(cat "$RUN_DIR/velocity.pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { echo "Velocity PID missing before JaCoCo teardown" >&2; return 1; }
  is_alive "$pid" || { echo "Velocity not alive before JaCoCo teardown" >&2; return 1; }
  kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! is_alive "$pid"; then
      return 0
    fi
    sleep 0.2
  done
  kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  return 0
}

start_stats_logger() {
  [[ "$AFLNET_STATS_LOG_INTERVAL" =~ ^[0-9]+$ ]] || return 0
  [[ "$AFLNET_STATS_LOG_INTERVAL" -gt 0 ]] || return 0
  : >"$WATCH_STATS_LOG"
  (
    while true; do
      printf '%s ' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      "$ROOT/scripts/watch-aflnet-stats.sh" --once "$RUN_DIR"
      sleep "$AFLNET_STATS_LOG_INTERVAL"
    done
  ) >>"$WATCH_STATS_LOG" 2>&1 &
  watch_stats_pid=$!
}

stop_stats_logger() {
  if [[ -n "$watch_stats_pid" ]]; then
    kill "$watch_stats_pid" 2>/dev/null || true
    wait "$watch_stats_pid" 2>/dev/null || true
    watch_stats_pid=""
  fi
}

append_jacoco_summary() {
  [[ "$ENABLE_JACOCO" == "1" ]] || return 0
  {
    echo "jacoco_enabled=1"
    echo "coverage_tool=jacoco"
    echo "coverage_role=human-readable-reporting"
    echo "jacoco_window_mode=$JACOCO_WINDOW_MODE"
    if [[ "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
      echo "jacoco_coverage_phase=campaign-epoch"
      echo "jacoco_coverage_includes_startup=no"
      echo "jacoco_coverage_includes_preflight=no"
      echo "jacoco_coverage_includes_aflnet_campaign=yes"
      echo "jacoco_coverage_includes_teardown=no"
      echo "jacoco_startup_exec=$JACOCO_STARTUP_EXEC"
      echo "jacoco_dump_transport=tcpserver"
      echo "jacoco_dump_port=$JACOCO_TCP_PORT"
    else
      echo "jacoco_coverage_phase=whole-process"
      echo "jacoco_coverage_includes_startup=yes"
      echo "jacoco_coverage_includes_preflight=yes"
      echo "jacoco_coverage_includes_aflnet_campaign=yes"
      echo "jacoco_coverage_includes_teardown=yes"
    fi
    echo "velocity_process_status_before_jacoco_teardown=alive"
    echo "velocity_terminated_for_jacoco_dump=yes"
    echo "jacoco_agent=$JACOCO_AGENT_EXTRACTED"
    echo "jacoco_exec=$JACOCO_EXEC"
    echo "jacoco_report_xml=$JACOCO_XML"
    echo "jacoco_report_html=$JACOCO_HTML_DIR"
    echo "jacoco_report_log=$JACOCO_REPORT_LOG"
  } >>"$SUMMARY"
}

git_commit() {
  git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unavailable
}

git_dirty() {
  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo unavailable
  elif [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    echo yes
  else
    echo no
  fi
}

campaign_role() {
  if [[ "$ENABLE_JACOCO" == "1" ]]; then
    echo "coverage-reporting-smoke"
  else
    echo "smoke"
  fi
}

validate_feedback_mode() {
  case "$AFLNET_FEEDBACK_MODE" in
    state-aware|code-only|state-only) ;;
    *) echo "Unsupported AFLNET_FEEDBACK_MODE: $AFLNET_FEEDBACK_MODE" >&2; exit 9 ;;
  esac
}

validate_jacoco_window_mode() {
  case "$JACOCO_WINDOW_MODE" in
    whole-process|campaign-epoch) ;;
    *) echo "Unsupported JACOCO_WINDOW_MODE: $JACOCO_WINDOW_MODE" >&2; exit 9 ;;
  esac
}

aflnet_state_aware_enabled() {
  case "$AFLNET_FEEDBACK_MODE" in
    state-aware|state-only) echo yes ;;
    code-only) echo no ;;
  esac
}

aflnet_feedback_type() {
  case "$AFLNET_FEEDBACK_MODE" in
    state-aware) echo state-aware+code ;;
    code-only) echo code-only ;;
    state-only) echo state-only ;;
  esac
}

edge_feedback_enabled() {
  case "$AFLNET_FEEDBACK_MODE" in
    state-aware|code-only) return 0 ;;
    state-only) return 1 ;;
  esac
}

state_feedback_enabled() {
  case "$AFLNET_FEEDBACK_MODE" in
    state-aware|state-only) return 0 ;;
    code-only) return 1 ;;
  esac
}

velocity_process_status() {
  if [[ ! -f "$RUN_DIR/velocity.pid" ]]; then
    echo "missing"
    return
  fi
  local pid
  pid="$(cat "$RUN_DIR/velocity.pid")"
  if [[ -z "$pid" ]]; then
    echo "unknown"
  elif is_alive "$pid"; then
    echo "alive"
  else
    echo "exited"
  fi
}

summarize() {
  grep '\[afl-mc-agent\]' "$VELOCITY_LOG" >"$AGENT_LOG" 2>/dev/null || true

  local execs_done execs_per_sec queue_count crashes hangs replayable_crashes replayable_hangs state_paths state_evidence edge_evidence agent_engine target_alive aflnet_exit
  local process_status classification_summary feedback_metrics_summary
  execs_done="$(stat_value execs_done)"
  execs_per_sec="$(stat_value execs_per_sec)"
  queue_count="$(count_files "$AFL_OUT/queue")"
  crashes="$(count_files "$AFL_OUT/crashes")"
  hangs="$(count_files "$AFL_OUT/hangs")"
  replayable_crashes="$(count_files "$AFL_OUT/replayable-crashes")"
  replayable_hangs="$(count_files "$AFL_OUT/replayable-hangs")"
  state_paths="$(count_files "$AFL_OUT/replayable-new-ipsm-paths")"
  agent_engine="$(grep -m1 '\[afl-mc-agent\] Engine:' "$VELOCITY_LOG" | sed 's/^.*Engine: //' || true)"
  [[ -n "$agent_engine" ]] || agent_engine="unknown"
  if [[ "$state_paths" -gt 0 || -s "$AFL_OUT/ipsm.dot" ]]; then
    state_evidence="observable"
  else
    state_evidence="none"
  fi
  if grep -q 'ShmCoverageEngine' "$VELOCITY_LOG" 2>/dev/null; then
    edge_evidence="shm-attached"
  elif grep -q '\[afl-mc-agent\] Agent ready' "$VELOCITY_LOG" 2>/dev/null; then
    edge_evidence="agent-loaded-no-shm"
  else
    edge_evidence="none"
  fi
  process_status="$(velocity_process_status)"
  classification_summary="$(VELOCITY_PROCESS_STATUS="$process_status" "$ROOT/scripts/classify-campaign-logs.sh" "$VELOCITY_LOG" "$SQUID_LOG" "$AFLNET_LOG")"
  if [[ -d "$AFL_OUT" ]]; then
    feedback_metrics_summary="$("$ROOT/scripts/extract-campaign-feedback-metrics.sh" "$RUN_DIR" || true)"
  else
    feedback_metrics_summary=$'state_coverage_metric_status=unavailable\nstate_coverage_metric_reason=missing-aflnet-output-directory\nedge_coverage_metric_status=unavailable\nedge_coverage_metric_reason=missing-aflnet-output-directory\nafl_bitmap_metric_status=unavailable'
  fi
  target_alive="no"
  if [[ "$process_status" == "alive" ]]; then
    target_alive="yes"
  fi
  aflnet_exit="$(cat "$RUN_DIR/aflnet.exit" 2>/dev/null || echo unavailable)"
  aflnet_exit_class="$(classify_aflnet_exit "$aflnet_exit")"

  {
    echo "campaign_status=PENDING"
    echo "run_dir=$RUN_DIR"
    echo "campaign_role=$(campaign_role)"
    echo "git_commit=$(git_commit)"
    echo "git_dirty=$(git_dirty)"
    echo "target_backend=flying-squid"
    echo "velocity_config=$ROOT/velocity/velocity.toml"
    echo "campaign_seconds=$CAMPAIGN_SECONDS"
    echo "aflnet_protocol=MC"
    echo "aflnet_binary=$AFLNET_BIN"
    echo "aflnet_binary_mode=$AFLNET_BINARY_MODE"
    echo "aflnet_local_smoke_workaround=$AFLNET_USE_LOCAL_SMOKE_BINARY"
    echo "aflnet_startup_delay_usec=$AFLNET_STARTUP_DELAY_USEC"
    echo "aflnet_poll_wait_ms=$AFLNET_POLL_WAIT_MS"
    echo "aflnet_socket_timeout_usec=$AFLNET_SOCKET_TIMEOUT_USEC"
    echo "aflnet_exec_timeout_ms=$AFLNET_EXEC_TIMEOUT_MS"
    echo "campaign_seed_glob=$CAMPAIGN_SEED_GLOB"
    echo "aflnet_feedback_mode=$AFLNET_FEEDBACK_MODE"
    echo "aflnet_state_aware_enabled=$(aflnet_state_aware_enabled)"
    echo "aflnet_feedback_type=$(aflnet_feedback_type)"
    if edge_feedback_enabled; then
      echo "afl_shm_id=${AFL_SHM_ID:-unavailable}"
      echo "aflnet_reuse_shm_id=1"
    else
      echo "afl_shm_id=disabled"
      echo "aflnet_reuse_shm_id=0"
    fi
    echo "jacoco_enabled=$ENABLE_JACOCO"
    if [[ "$AFLNET_STATS_LOG_INTERVAL" =~ ^[0-9]+$ && "$AFLNET_STATS_LOG_INTERVAL" -gt 0 ]]; then
      echo "aflnet_stats_log=$WATCH_STATS_LOG"
      echo "aflnet_stats_log_interval=$AFLNET_STATS_LOG_INTERVAL"
    else
      echo "aflnet_stats_log=disabled"
      echo "aflnet_stats_log_interval=0"
    fi
    echo "aflnet_exit=$aflnet_exit"
    echo "aflnet_exit_class=$aflnet_exit_class"
    echo "execs_done=${execs_done:-unavailable}"
    echo "execs_per_sec=${execs_per_sec:-unavailable}"
    echo "queue_count=$queue_count"
    echo "crashes=$crashes"
    echo "hangs=$hangs"
    echo "replayable_crashes=$replayable_crashes"
    echo "replayable_hangs=$replayable_hangs"
    echo "state_feedback_evidence=$state_evidence"
    echo "state_path_artifacts=$state_paths"
    echo "edge_feedback_evidence=$edge_evidence"
    echo "agent_engine=$agent_engine"
    printf '%s\n' "$feedback_metrics_summary"
    printf '%s\n' "$classification_summary"
    echo "velocity_alive_after_campaign=$target_alive"
    echo "velocity_log=$VELOCITY_LOG"
    echo "backend_log=$SQUID_LOG"
    echo "aflnet_log=$AFLNET_LOG"
    echo "edge_metrics_log=$EDGE_METRICS_LOG"
  } > "$SUMMARY"
}

mark_pass() {
  sed -i 's/^campaign_status=PENDING$/campaign_status=PASS/' "$SUMMARY"
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

is_allowed_aflnet_exit_class() {
  case "$1" in
    clean|controlled-timeout|controlled-interrupt|controlled-sigterm) return 0 ;;
    *) return 1 ;;
  esac
}

fail_campaign() {
  local message="$1"
  summarize || true
  sed -i 's/^campaign_status=PENDING$/campaign_status=FAIL/' "$SUMMARY" 2>/dev/null || true
  echo "FAIL: $message" >&2
  echo "RUN_DIR=$RUN_DIR" >&2
  echo "summary=$SUMMARY" >&2
  exit 1
}

if [[ "$RESUME" != "1" && -e "$AFL_OUT" ]]; then
  echo "AFLNet output already exists; choose a new RUN_ID/CAMPAIGN_RUN_DIR or set RESUME=1: $AFL_OUT" >&2
  exit 6
fi

require_file "$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
require_file "$ROOT/afl-mc-agent/libaflmcshm.so"
require_file "$ROOT/velocity/proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar"
require_file "$ROOT/prismarinejs/flying-squid/app.js"
require_file "$ROOT/scripts/test-connection.js"
require_file "$ROOT/scripts/classify-campaign-logs.sh"
require_file "$ROOT/scripts/extract-campaign-feedback-metrics.sh"
require_file "$ROOT/scripts/watch-aflnet-stats.sh"
require_file "$ROOT/seeds/play-chat.bin"

validate_feedback_mode
validate_jacoco_window_mode
require_port_free 25565
require_port_free 30066
if [[ "$ENABLE_JACOCO" == "1" && "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
  require_port_free "$JACOCO_TCP_PORT"
fi
if edge_feedback_enabled; then
  ensure_campaign_shm
fi

copy_seed_corpus
prepare_jacoco_agent
if [[ "$AFLNET_USE_LOCAL_SMOKE_BINARY" == "1" ]]; then
  echo "Using opt-in generated local AFLNet smoke binary; this is a lifecycle compatibility workaround" > "$BUILD_LOG"
  build_local_smoke_aflnet
else
  require_file "$AFLNET_BIN"
  echo "Using repo-built AFLNet binary: $AFLNET_BIN" > "$BUILD_LOG"
fi

(
  cd "$ROOT/prismarinejs/flying-squid"
  setsid node app.js >"$SQUID_LOG" 2>&1 &
  echo $! > "$RUN_DIR/flying-squid.pid"
)
pidfiles+=("$RUN_DIR/flying-squid.pid")
wait_for_port 30066 || fail_campaign "flying-squid did not start"

(
  cd "$ROOT/velocity"
  if edge_feedback_enabled; then
    export __AFL_SHM_ID="$AFL_SHM_ID"
  else
    unset __AFL_SHM_ID
  fi
  java_cmd=(
    java
    -Djava.library.path="$ROOT/afl-mc-agent"
  )
  if [[ "$ENABLE_JACOCO" == "1" ]]; then
    if [[ "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
      java_cmd+=(-javaagent:"$JACOCO_AGENT_EXTRACTED=output=tcpserver,address=$JACOCO_TCP_ADDRESS,port=$JACOCO_TCP_PORT,dumponexit=false")
    else
      java_cmd+=(-javaagent:"$JACOCO_AGENT_EXTRACTED=destfile=$JACOCO_EXEC,append=false,dumponexit=true")
    fi
  fi
  java_cmd+=(
    -javaagent:"$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
    -Dafl.include="$AFL_INCLUDE"
  )
  if edge_feedback_enabled; then
    java_cmd+=(-Dafl.edgeMetricsFile="$EDGE_METRICS_LOG")
  fi
  if [[ -n "$AFL_EXCLUDE" ]]; then
    java_cmd+=(-Dafl.exclude="$AFL_EXCLUDE")
  fi
  java_cmd+=(
    -jar
    proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar
  )
  setsid "${java_cmd[@]}" >"$VELOCITY_LOG" 2>&1 &
  echo $! > "$RUN_DIR/velocity.pid"
)
pidfiles+=("$RUN_DIR/velocity.pid")
wait_for_port 25565 || fail_campaign "Velocity did not start"

grep -q '\[afl-mc-agent\] Agent ready' "$VELOCITY_LOG" || fail_campaign "javaagent did not report ready"
sleep 1
node "$ROOT/scripts/test-connection.js" >"$CONNECTION_LOG" 2>&1 || fail_campaign "preflight client did not reach PLAY"
if [[ "$ENABLE_JACOCO" == "1" && "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
  dump_jacoco_exec "$JACOCO_STARTUP_EXEC" 1 || fail_campaign "JaCoCo startup/preflight dump failed"
  [[ -s "$JACOCO_STARTUP_EXEC" ]] || fail_campaign "JaCoCo startup/preflight exec missing"
fi

mkdir -p "$AFL_OUT"
start_stats_logger
AFL_CMD=(
  "$AFLNET_BIN"
  -n
  -d
  -m none
  -t "$AFLNET_EXEC_TIMEOUT_MS"
  -i "$INPUT_DIR"
  -o "$AFL_OUT"
  -N tcp://127.0.0.1/25565
  -P MC
  -D "$AFLNET_STARTUP_DELAY_USEC"
  -W "$AFLNET_POLL_WAIT_MS"
  -w "$AFLNET_SOCKET_TIMEOUT_USEC"
)
if state_feedback_enabled; then
  AFL_CMD+=(
    -E
    -q 3
    -s 3
    -b 2
  )
else
  AFL_CMD+=(
    -h 1
  )
fi
AFL_CMD+=(
  -R
  -K
  /bin/sleep
  3600
)
printf '%q ' "${AFL_CMD[@]}" > "$RUN_DIR/aflnet-command.txt"
printf '\n' >> "$RUN_DIR/aflnet-command.txt"

set +e
(
  export AFL_NO_UI=1
  export AFL_SKIP_CPUFREQ=1
  export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
  export AFL_NO_AFFINITY=1
  if edge_feedback_enabled; then
    export __AFL_SHM_ID="$AFL_SHM_ID"
    export AFLNET_REUSE_SHM_ID=1
  else
    unset __AFL_SHM_ID AFLNET_REUSE_SHM_ID
  fi
  setsid timeout --signal=INT --kill-after=10s "${CAMPAIGN_SECONDS}s" "${AFL_CMD[@]}" >"$AFLNET_LOG" 2>&1 &
  echo $! > "$RUN_DIR/aflnet.pid"
  wait "$(cat "$RUN_DIR/aflnet.pid")"
)
af_exit=$?
set -e
pidfiles+=("$RUN_DIR/aflnet.pid")
echo "$af_exit" > "$RUN_DIR/aflnet.exit"
stop_stats_logger

summarize

[[ -d "$AFL_OUT" ]] || fail_campaign "AFLNet output directory missing"
[[ -s "$AFLNET_LOG" ]] || fail_campaign "AFLNet log missing"
[[ -s "$VELOCITY_LOG" ]] || fail_campaign "Velocity log missing"
[[ -s "$SQUID_LOG" ]] || fail_campaign "backend log missing"
[[ -f "$AFL_OUT/fuzzer_stats" ]] || fail_campaign "AFLNet fuzzer_stats missing"
aflnet_exit_class="$(classify_aflnet_exit "$(cat "$RUN_DIR/aflnet.exit" 2>/dev/null || echo unavailable)")"
is_allowed_aflnet_exit_class "$aflnet_exit_class" || fail_campaign "AFLNet exited unexpectedly: $aflnet_exit_class"
execs_done="$(stat_value execs_done)"
[[ "$execs_done" =~ ^[0-9]+$ ]] || fail_campaign "execs_done unavailable"
[[ "$execs_done" -gt 0 ]] || fail_campaign "execs_done is zero"
if [[ -f "$RUN_DIR/velocity.pid" ]] && ! is_alive "$(cat "$RUN_DIR/velocity.pid")"; then
  fail_campaign "Velocity died before campaign completed"
fi
if grep -q 'PROGRAM ABORT' "$AFLNET_LOG"; then
  fail_campaign "AFLNet aborted"
fi

if [[ "$ENABLE_JACOCO" == "1" ]]; then
  if [[ "$JACOCO_WINDOW_MODE" == "campaign-epoch" ]]; then
    dump_jacoco_exec "$JACOCO_EXEC" 0 || fail_campaign "JaCoCo campaign dump failed"
    [[ -s "$JACOCO_EXEC" ]] || fail_campaign "JaCoCo campaign exec missing before teardown"
    stop_velocity_for_jacoco_dump || fail_campaign "Velocity could not be stopped after JaCoCo campaign dump"
  else
    stop_velocity_for_jacoco_dump || fail_campaign "Velocity could not be stopped for JaCoCo dump"
  fi
  generate_jacoco_campaign_report || fail_campaign "JaCoCo campaign report generation failed"
  [[ -s "$JACOCO_EXEC" ]] || fail_campaign "JaCoCo exec missing after teardown"
  [[ -s "$JACOCO_XML" ]] || fail_campaign "JaCoCo XML missing"
  [[ -n "$(find "$JACOCO_HTML_DIR" -type f -print -quit 2>/dev/null)" ]] || fail_campaign "JaCoCo HTML report missing"
  append_jacoco_summary
fi

mark_pass

echo "RUN_DIR=$RUN_DIR"
echo "SUMMARY=$SUMMARY"
echo "WATCH_STATS_CMD=$ROOT/scripts/watch-aflnet-stats.sh $RUN_DIR"
echo "PASS: AFLNet campaign smoke"
