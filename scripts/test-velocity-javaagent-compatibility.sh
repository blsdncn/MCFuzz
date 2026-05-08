#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_JAR="$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
AGENT_LIB_DIR="$ROOT/afl-mc-agent"
VELOCITY_DIR="$ROOT/velocity"
RUN_ROOT="${JAVAAGENT_COMPAT_RUN_ROOT:-$ROOT/compat-runs}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_DIR="${JAVAAGENT_COMPAT_RUN_DIR:-$RUN_ROOT/$RUN_ID}"
LOG="$RUN_DIR/velocity-javaagent-compatibility.log"
INIT_SCRIPT="$RUN_DIR/velocity-javaagent-compatibility.init.gradle"
SUMMARY="$RUN_DIR/run-summary.txt"
AFL_INCLUDE="${AFL_INCLUDE:-com.velocitypowered.*}"
AFL_EXCLUDE="${AFL_EXCLUDE:-com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket}"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing required file: $path" >&2; exit 2; }
}

fail() {
  local message="$1"
  {
    echo "compatibility_status=FAIL"
    echo "reason=$message"
    echo "run_dir=$RUN_DIR"
    echo "log=$LOG"
    echo "agent_engine=unknown"
    echo "afl_include=$AFL_INCLUDE"
    echo "afl_exclude=$AFL_EXCLUDE"
  } >"$SUMMARY" 2>/dev/null || true
  echo "FAIL: $message" >&2
  echo "RUN_DIR=$RUN_DIR" >&2
  echo "LOG=$LOG" >&2
  if [[ -f "$LOG" ]]; then
    echo "--- log tail ---" >&2
    tail -80 "$LOG" >&2 || true
  fi
  exit 1
}

require_file "$AGENT_JAR"
require_file "$VELOCITY_DIR/gradlew"
mkdir -p "$RUN_DIR"

cat >"$INIT_SCRIPT" <<EOF
import org.gradle.api.tasks.testing.Test

allprojects {
  tasks.withType(Test).configureEach { testTask ->
    testTask.jvmArgs(
      '-javaagent:$AGENT_JAR',
      '-Djava.library.path=$AGENT_LIB_DIR',
      '-Dafl.include=$AFL_INCLUDE',
      '-Dafl.exclude=$AFL_EXCLUDE'
    )
    testTask.maxParallelForks = 1
    testTask.testLogging {
      showStandardStreams = true
      events 'passed', 'skipped', 'failed'
      exceptionFormat 'full'
    }
  }
}
EOF

TEST_ARGS=(
  :velocity-proxy:test
  --tests com.velocitypowered.proxy.protocol.PacketRegistryTest
  --tests com.velocitypowered.proxy.connection.client.HandshakeSessionHandlerTest
  --tests com.velocitypowered.proxy.protocol.ProtocolUtilsTest
  --no-daemon
  --offline
  --rerun-tasks
  --init-script "$INIT_SCRIPT"
)

set +e
(
  cd "$VELOCITY_DIR"
  env -u __AFL_SHM_ID -u AFLNET_REUSE_SHM_ID ./gradlew "${TEST_ARGS[@]}"
) >"$LOG" 2>&1
gradle_exit=$?
set -e

echo "gradle_exit=$gradle_exit" >"$RUN_DIR/gradle.exit"
[[ "$gradle_exit" -eq 0 ]] || fail "velocity-test-subset-failed"

grep -q '\[afl-mc-agent\] Agent ready' "$LOG" || fail "javaagent-did-not-report-ready"
grep -q '\[afl-mc-agent\] Engine: NoOpCoverageEngine' "$LOG" || fail "javaagent-did-not-use-noop-engine"
grep -q "\[afl-mc-agent\] Include patterns: $AFL_INCLUDE" "$LOG" || fail "javaagent-include-scope-not-observed"
grep -q "\[afl-mc-agent\] Exclude patterns: $AFL_EXCLUDE" "$LOG" || fail "generic-title-packet-exclusion-not-observed"

if grep -Eq 'VerifyError|LinkageError|ClassFormatError|ClassCircularityError|IllegalClassFormatException|NoClassDefFoundError: afl[/.]AflCoverage' "$LOG"; then
  fail "instrumentation-compatibility-error-observed"
fi

instrumented_summary="$(grep -E '\[afl-mc-agent\] Shutdown: instrumented [0-9]+ classes, [0-9]+ total edges' "$LOG" | tail -1 || true)"
[[ -n "$instrumented_summary" ]] || fail "javaagent-shutdown-summary-missing"

{
  echo "compatibility_status=PASS"
  echo "run_dir=$RUN_DIR"
  echo "log=$LOG"
  echo "gradle_exit=$gradle_exit"
  echo "velocity_test_task=:velocity-proxy:test"
  echo "velocity_test_subset=com.velocitypowered.proxy.protocol.PacketRegistryTest,com.velocitypowered.proxy.connection.client.HandshakeSessionHandlerTest,com.velocitypowered.proxy.protocol.ProtocolUtilsTest"
  echo "javaagent=$AGENT_JAR"
  echo "agent_engine=NoOpCoverageEngine"
  echo "afl_include=$AFL_INCLUDE"
  echo "afl_exclude=$AFL_EXCLUDE"
  echo "instrumented_summary=$instrumented_summary"
} >"$SUMMARY"

echo "RUN_DIR=$RUN_DIR"
echo "SUMMARY=$SUMMARY"
echo "PASS: Velocity javaagent compatibility"
