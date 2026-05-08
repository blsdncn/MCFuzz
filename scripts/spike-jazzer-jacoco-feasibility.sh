#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JAZZER_ROOT="${JAZZER_ROOT:-$ROOT/velocity-jazzer-integration}"
MODE="${MODE:-stateful}" # stateful|stateless
TIME_LIMIT="${TIME_LIMIT:-120}"
RESET_OUTPUTS="${RESET_OUTPUTS:-1}"
SPIKE_ID="${SPIKE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${MODE}}"
SPIKE_DIR="${SPIKE_DIR:-$JAZZER_ROOT/build/jazzer-jacoco-feasibility/$SPIKE_ID}"

require_file() {
  local p="$1"
  [[ -f "$p" ]] || { echo "missing file: $p" >&2; exit 2; }
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }
}

require_tool python3
require_tool java
require_tool unzip

[[ -d "$JAZZER_ROOT" ]] || { echo "JAZZER_ROOT not found: $JAZZER_ROOT" >&2; exit 2; }

case "$MODE" in
  stateful)
    RUN_SCRIPT="$JAZZER_ROOT/scripts/run-jazzer-direct.sh"
    TARGET_CLASS_FILE="$JAZZER_ROOT/proxy/build/classes/java/test/com/velocitypowered/proxy/fuzz/VelocityProtocolStateFuzzTarget.class"
    JAZZER_WORK_DIR="$JAZZER_ROOT/build/jazzer"
    ;;
  stateless)
    RUN_SCRIPT="$JAZZER_ROOT/scripts/run-jazzer-direct-stateless.sh"
    TARGET_CLASS_FILE="$JAZZER_ROOT/proxy/build/classes/java/test/com/velocitypowered/proxy/fuzz/VelocityProtocolStateless.class"
    JAZZER_WORK_DIR="$JAZZER_ROOT/build/jazzer-stateless"
    ;;
  *)
    echo "unsupported MODE=$MODE (expected stateful|stateless)" >&2
    exit 2
    ;;
esac

require_file "$RUN_SCRIPT"
require_file "$ROOT/scripts/resolve-jacoco-outer-jar.sh"
require_file "$ROOT/scripts/resolve-jacoco-cli-jar.sh"

mkdir -p "$SPIKE_DIR"
SPIKE_DIR="$(cd "$SPIKE_DIR" && pwd)"

echo "[1/7] Resolve JaCoCo artifacts"
JACOCO_AGENT_OUTER_JAR="$("$ROOT/scripts/resolve-jacoco-outer-jar.sh" "${JACOCO_AGENT_OUTER_JAR:-}")"
JACOCO_CLI_JAR="$("$ROOT/scripts/resolve-jacoco-cli-jar.sh" "${JACOCO_CLI_JAR:-}")"
require_file "$JACOCO_AGENT_OUTER_JAR"
require_file "$JACOCO_CLI_JAR"

JACOCO_AGENT_JAR="$SPIKE_DIR/jacocoagent.jar"
JACOCO_EXEC="$SPIKE_DIR/jazzer.exec"
JACOCO_REPORT_DIR="$SPIKE_DIR/report"
JACOCO_XML="$JACOCO_REPORT_DIR/jacoco.xml"
JACOCO_HTML_DIR="$JACOCO_REPORT_DIR/html"
INIT_SCRIPT="$SPIKE_DIR/jacoco-fuzz-report.init.gradle"
RUN_LOG="$SPIKE_DIR/run.log"
SUMMARY="$SPIKE_DIR/feasibility-summary.txt"

unzip -p "$JACOCO_AGENT_OUTER_JAR" jacocoagent.jar >"$JACOCO_AGENT_JAR"
require_file "$JACOCO_AGENT_JAR"

if [[ ! -f "$TARGET_CLASS_FILE" ]]; then
  echo "[2/7] Build fuzz target test classes"
  (
    cd "$JAZZER_ROOT"
    ./gradlew :velocity-proxy:testClasses --offline --no-daemon >/dev/null 2>&1 || ./gradlew :velocity-proxy:testClasses --no-daemon >/dev/null 2>&1
  )
fi
require_file "$TARGET_CLASS_FILE"

echo "[3/7] Run Jazzer with JaCoCo javaagent (MODE=$MODE, TIME_LIMIT=$TIME_LIMIT)"
PREV_JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS-}"
AGENT_OPTS="-javaagent:$JACOCO_AGENT_JAR=destfile=$JACOCO_EXEC,append=false,output=file,inclnolocationclasses=true"
if [[ -n "$PREV_JAVA_TOOL_OPTIONS" ]]; then
  export JAVA_TOOL_OPTIONS="$PREV_JAVA_TOOL_OPTIONS $AGENT_OPTS"
else
  export JAVA_TOOL_OPTIONS="$AGENT_OPTS"
fi

set +e
(
  cd "$JAZZER_ROOT"
  TIME_LIMIT="$TIME_LIMIT" RESET_OUTPUTS="$RESET_OUTPUTS" bash "$RUN_SCRIPT"
) >"$RUN_LOG" 2>&1
JAZZER_EXIT=$?
set -e

if [[ -n "$PREV_JAVA_TOOL_OPTIONS" ]]; then
  export JAVA_TOOL_OPTIONS="$PREV_JAVA_TOOL_OPTIONS"
else
  unset JAVA_TOOL_OPTIONS || true
fi

echo "[4/7] Capture Jazzer outputs"
mkdir -p "$SPIKE_DIR/jazzer-work"
if [[ -d "$JAZZER_WORK_DIR" ]]; then
  cp -f "$JAZZER_WORK_DIR/summary.txt" "$SPIKE_DIR/jazzer-work/" 2>/dev/null || true
  cp -f "$JAZZER_WORK_DIR/logs/jazzer-faults.txt" "$SPIKE_DIR/jazzer-work/" 2>/dev/null || true
  cp -f "$JAZZER_WORK_DIR/logs/jazzer-artifacts.txt" "$SPIKE_DIR/jazzer-work/" 2>/dev/null || true
  cp -f "$JAZZER_WORK_DIR/logs/jazzer-stderr.log" "$SPIKE_DIR/jazzer-work/" 2>/dev/null || true
  cp -f "$JAZZER_WORK_DIR/coverage/jazzer-coverage" "$SPIKE_DIR/jazzer-work/" 2>/dev/null || true
fi

echo "[5/7] Generate JaCoCo XML report from fuzz exec"
mkdir -p "$JACOCO_REPORT_DIR" "$JACOCO_HTML_DIR"
cat >"$INIT_SCRIPT" <<'EOF'
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

  rootProject.tasks.register('jacocoFuzzReport', JacocoReport) { reportTask ->
    reportTask.group = 'verification'
    reportTask.description = 'Generates aggregate JaCoCo report for Jazzer fuzz run coverage.'
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

JACOCO_REPORT_LOG="$SPIKE_DIR/jacoco-report.log"
REPORT_EXIT=0
set +e
(
  cd "$JAZZER_ROOT"
  ./gradlew jacocoFuzzReport --offline --no-daemon --init-script "$INIT_SCRIPT" -DjacocoExecFile="$JACOCO_EXEC" -DjacocoReportDir="$JACOCO_REPORT_DIR"
) >"$JACOCO_REPORT_LOG" 2>&1
REPORT_EXIT=$?
set -e
if [[ "$REPORT_EXIT" -ne 0 ]]; then
  set +e
  (
    cd "$JAZZER_ROOT"
    ./gradlew jacocoFuzzReport --no-daemon --init-script "$INIT_SCRIPT" -DjacocoExecFile="$JACOCO_EXEC" -DjacocoReportDir="$JACOCO_REPORT_DIR"
  ) >>"$JACOCO_REPORT_LOG" 2>&1
  REPORT_EXIT=$?
  set -e
fi

echo "[6/7] Validate feasibility outputs"
EXEC_SIZE=0
XML_SIZE=0
COUNTER_LINES=0
if [[ -f "$JACOCO_EXEC" ]]; then EXEC_SIZE="$(stat -c %s "$JACOCO_EXEC")"; fi
if [[ -f "$JACOCO_XML" ]]; then XML_SIZE="$(stat -c %s "$JACOCO_XML")"; fi
if [[ -f "$JACOCO_XML" ]]; then COUNTER_LINES="$(grep -o '<counter type=' "$JACOCO_XML" | wc -l | tr -d ' ' )"; fi

JAZZER_EXIT_CLASS="unexpected"
case "$JAZZER_EXIT" in
  0) JAZZER_EXIT_CLASS="clean" ;;
  1) JAZZER_EXIT_CLASS="findings-or-libfuzzer-nonzero" ;;
  77) JAZZER_EXIT_CLASS="libfuzzer-oom-timeout-style" ;;
  *) JAZZER_EXIT_CLASS="unexpected" ;;
esac

STATUS="FAIL"
if [[ "$REPORT_EXIT" -eq 0 && "$EXEC_SIZE" -gt 0 && "$XML_SIZE" -gt 0 && "$COUNTER_LINES" -gt 0 && "$JAZZER_EXIT_CLASS" != "unexpected" ]]; then
  STATUS="PASS"
fi

{
  echo "spike_id=$SPIKE_ID"
  echo "mode=$MODE"
  echo "time_limit=$TIME_LIMIT"
  echo "jazzer_root=$JAZZER_ROOT"
  echo "jazzer_exit=$JAZZER_EXIT"
  echo "jazzer_exit_class=$JAZZER_EXIT_CLASS"
  echo "jacoco_report_exit=$REPORT_EXIT"
  echo "jacoco_exec=$JACOCO_EXEC"
  echo "jacoco_exec_size=$EXEC_SIZE"
  echo "jacoco_xml=$JACOCO_XML"
  echo "jacoco_xml_size=$XML_SIZE"
  echo "jacoco_xml_counter_lines=$COUNTER_LINES"
  echo "jazzer_run_log=$RUN_LOG"
  echo "jacoco_report_log=$JACOCO_REPORT_LOG"
  echo "feasibility_status=$STATUS"
} >"$SUMMARY"

echo "[7/7] Done"
echo "summary=$SUMMARY"
echo "feasibility_status=$STATUS"

if [[ "$STATUS" != "PASS" ]]; then
  exit 1
fi
