#!/usr/bin/env bash
set -euo pipefail

# KNOWN-BUG REPRODUCTION SCRIPT.
#
# This diagnostic target documents today's failure mode when Velocity runs with
# the AFL javaagent and no title-packet exclusion. It is not desired behavior and
# should not be used as a default passing CI/test target. When the bug is fixed,
# this script should be retired or inverted in favor of
# test-title-packet-no-exclusion-desired.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
VELOCITY_LOG="$TMPDIR/velocity.log"
SQUID_LOG="$TMPDIR/flying-squid.log"
CLIENT_OUT="$TMPDIR/client.out"

cleanup() {
  for pidfile in "$TMPDIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

kill_port() {
  local port="$1"
  local pids
  pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 1
    kill -9 $pids 2>/dev/null || true
  fi
}

wait_for_port() {
  local port="$1"
  local attempts="${2:-150}"
  for _ in $(seq 1 "$attempts"); do
    if ss -tln | grep -q ":$port "; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_port_free() {
  local port="$1"
  local attempts="${2:-150}"
  for _ in $(seq 1 "$attempts"); do
    if ! ss -tln | grep -q ":$port "; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing required file: $path" >&2; exit 2; }
}

require_file "$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
require_file "$ROOT/velocity/proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar"
require_file "$ROOT/prismarinejs/flying-squid/app.js"
require_file "$ROOT/scripts/test-connection.js"

kill_port 25565
kill_port 30066
wait_for_port_free 25565 || { echo "port 25565 still in use after cleanup" >&2; ss -tlnp 2>/dev/null | grep ':25565 ' >&2 || true; exit 7; }
wait_for_port_free 30066 || { echo "port 30066 still in use after cleanup" >&2; ss -tlnp 2>/dev/null | grep ':30066 ' >&2 || true; exit 8; }

echo "[title-packet-known-bug-repro] Starting stack with no title-packet exclusion to reproduce the known instrumentation bug"

(
  cd "$ROOT/prismarinejs/flying-squid"
  nohup node app.js >"$SQUID_LOG" 2>&1 &
  echo $! > "$TMPDIR/flying-squid.pid"
)
wait_for_port 30066 || { echo "flying-squid failed to start" >&2; cat "$SQUID_LOG" >&2; exit 3; }

(
  cd "$ROOT/velocity"
  nohup java \
    -javaagent:"$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar" \
    -Dafl.include=com.velocitypowered.* \
    -jar proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar \
    >"$VELOCITY_LOG" 2>&1 &
  echo $! > "$TMPDIR/velocity.pid"
)
wait_for_port 25565 || { echo "Velocity failed to start" >&2; cat "$VELOCITY_LOG" >&2; exit 4; }

grep -q "\[afl-mc-agent\] Agent ready" "$VELOCITY_LOG" || {
  echo "Agent did not report ready" >&2
  cat "$VELOCITY_LOG" >&2
  exit 5
}

sleep 1

if node "$ROOT/scripts/test-connection.js" >"$CLIENT_OUT" 2>&1; then
  echo "Expected connection failure without the temporary title-packet exclusion, but login reached PLAY" >&2
  cat "$CLIENT_OUT" >&2
  exit 6
fi

grep -q "java.lang.LinkageError" "$VELOCITY_LOG"
grep -q "GenericTitlePacket" "$VELOCITY_LOG"
grep -q "ERROR: read ECONNRESET" "$CLIENT_OUT"

echo "PASS: reproduced known title-packet instrumentation bug without exclusion"
