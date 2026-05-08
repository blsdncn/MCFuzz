#!/usr/bin/env bash
set -euo pipefail

# NON-DEFAULT DESIRED-FUTURE COMPATIBILITY TARGET.
#
# This script defines the exit condition for removing the temporary
# GenericTitlePacket instrumentation exclusion. It is expected to FAIL until the
# underlying instrumentation/linkage bug is fixed.
#
# Desired behavior:
#   - Velocity runs with the AFL javaagent and NO title-packet exclusion.
#   - A real Prismarine client reaches PLAY state through Velocity -> backend.
#   - Velocity does not log LinkageError for GenericTitlePacket or any other class.
#   - A real raw Minecraft seed can replay and produce AFLNet state transitions.
#
# Do not add this script to default CI/test paths until the project has an
# expected-failure mechanism, or until the bug is fixed and this target passes.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-$ROOT/seeds/play-chat.bin}"
TMPDIR="$(mktemp -d)"
VELOCITY_LOG="$TMPDIR/velocity.log"
SQUID_LOG="$TMPDIR/flying-squid.log"
CLIENT_OUT="$TMPDIR/client.out"
TRANSITIONS_OUT="$TMPDIR/transitions.out"

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

fail_with_logs() {
  local message="$1"
  echo "$message" >&2
  echo "--- client output ---" >&2
  cat "$CLIENT_OUT" >&2 2>/dev/null || true
  echo "--- transition output ---" >&2
  cat "$TRANSITIONS_OUT" >&2 2>/dev/null || true
  echo "--- Velocity LinkageError lines ---" >&2
  grep -n "LinkageError\|GenericTitlePacket" "$VELOCITY_LOG" >&2 2>/dev/null || true
  echo "--- Velocity log tail ---" >&2
  tail -120 "$VELOCITY_LOG" >&2 2>/dev/null || true
  echo "--- flying-squid log tail ---" >&2
  tail -80 "$SQUID_LOG" >&2 2>/dev/null || true
  exit 1
}

require_file "$SEED"
require_file "$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
require_file "$ROOT/velocity/proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar"
require_file "$ROOT/prismarinejs/flying-squid/app.js"
require_file "$ROOT/scripts/test-connection.js"
require_file "$ROOT/scripts/test-state-transitions.c"

kill_port 25565
kill_port 30066
wait_for_port_free 25565 || { echo "port 25565 still in use after cleanup" >&2; ss -tlnp 2>/dev/null | grep ':25565 ' >&2 || true; exit 7; }
wait_for_port_free 30066 || { echo "port 30066 still in use after cleanup" >&2; ss -tlnp 2>/dev/null | grep ':30066 ' >&2 || true; exit 8; }

echo "[title-packet-desired] Starting stack with no GenericTitlePacket exclusion"
echo "[title-packet-desired] This is a non-default desired-future target and may fail until the known bug is fixed"

# Rebuild the replay/transition harness so this target always uses current code.
gcc -O3 -Wall -g -I"$ROOT/aflnet" -Wno-pointer-sign -Wno-unused-result \
  "$ROOT/scripts/test-state-transitions.c" "$ROOT/aflnet/aflnet.c" \
  -o "$ROOT/scripts/test-state-transitions" -ldl -lm >/dev/null 2>&1

(
  cd "$ROOT/prismarinejs/flying-squid"
  nohup node app.js >"$SQUID_LOG" 2>&1 &
  echo $! > "$TMPDIR/flying-squid.pid"
)
wait_for_port 30066 || fail_with_logs "flying-squid failed to start"

(
  cd "$ROOT/velocity"
  nohup java \
    -javaagent:"$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar" \
    -Dafl.include=com.velocitypowered.* \
    -jar proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar \
    >"$VELOCITY_LOG" 2>&1 &
  echo $! > "$TMPDIR/velocity.pid"
)
wait_for_port 25565 || fail_with_logs "Velocity failed to start"

grep -q "\[afl-mc-agent\] Agent ready" "$VELOCITY_LOG" || \
  fail_with_logs "Agent did not report ready"

sleep 1

node "$ROOT/scripts/test-connection.js" >"$CLIENT_OUT" 2>&1 || \
  fail_with_logs "Desired behavior failed: client did not reach PLAY without GenericTitlePacket exclusion"

if grep -q "java.lang.LinkageError" "$VELOCITY_LOG"; then
  fail_with_logs "Desired behavior failed: Velocity logged LinkageError without GenericTitlePacket exclusion"
fi

"$ROOT/scripts/test-state-transitions" --replay-seed "$SEED" 1 >"$TRANSITIONS_OUT" 2>&1 || \
  fail_with_logs "Desired behavior failed: state-transition replay failed without GenericTitlePacket exclusion"

if grep -q "java.lang.LinkageError" "$VELOCITY_LOG"; then
  fail_with_logs "Desired behavior failed: Velocity logged LinkageError after state-transition replay"
fi

echo "PASS: full stack works without GenericTitlePacket exclusion"
