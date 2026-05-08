#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-$ROOT/seeds/play-chat.bin}"
AFL_INCLUDE="${AFL_INCLUDE:-com.velocitypowered.*}"
AFL_EXCLUDE="${AFL_EXCLUDE:-com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket}"
TMPDIR="$(mktemp -d)"
VELOCITY_LOG="$TMPDIR/velocity.log"
SQUID_LOG="$TMPDIR/flying-squid.log"

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

echo "[run-stack-smoke] Agent include patterns: $AFL_INCLUDE"
if [[ -n "$AFL_EXCLUDE" ]]; then
  echo "[run-stack-smoke] Temporary instrumentation exclusion active: $AFL_EXCLUDE"
else
  echo "[run-stack-smoke] Temporary instrumentation exclusion disabled"
fi

# Rebuild the replay/transition harness so this smoke test always uses current code.
gcc -O3 -Wall -g -I"$ROOT/aflnet" -Wno-pointer-sign -Wno-unused-result \
  "$ROOT/scripts/test-state-transitions.c" "$ROOT/aflnet/aflnet.c" \
  -o "$ROOT/scripts/test-state-transitions" -ldl -lm >/dev/null 2>&1

(
  cd "$ROOT/prismarinejs/flying-squid"
  nohup node app.js >"$SQUID_LOG" 2>&1 &
  echo $! > "$TMPDIR/flying-squid.pid"
)
wait_for_port 30066 || { echo "flying-squid failed to start" >&2; cat "$SQUID_LOG" >&2; exit 3; }

(
  cd "$ROOT/velocity"
  java_cmd=(
    java
    -javaagent:"$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
    -Dafl.include="$AFL_INCLUDE"
  )
  if [[ -n "$AFL_EXCLUDE" ]]; then
    java_cmd+=(-Dafl.exclude="$AFL_EXCLUDE")
  fi
  java_cmd+=(
    -jar
    proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar
  )
  nohup "${java_cmd[@]}" >"$VELOCITY_LOG" 2>&1 &
  echo $! > "$TMPDIR/velocity.pid"
)
wait_for_port 25565 || { echo "Velocity failed to start" >&2; cat "$VELOCITY_LOG" >&2; exit 4; }

grep -q "\[afl-mc-agent\] Agent ready" "$VELOCITY_LOG" || {
  echo "Agent did not report ready" >&2
  cat "$VELOCITY_LOG" >&2
  exit 5
}

if [[ -n "$AFL_EXCLUDE" ]]; then
  exclude_log="$(grep -m1 "\[afl-mc-agent\] Exclude patterns:" "$VELOCITY_LOG" || true)"
  [[ -n "$exclude_log" ]] || {
    echo "Agent did not log exclude patterns" >&2
    cat "$VELOCITY_LOG" >&2
    exit 6
  }
  echo "$exclude_log"
fi

# The ports can be open slightly before the proxy/backend are fully ready for a clean login flow.
sleep 1

node "$ROOT/scripts/test-connection.js" >/dev/null
"$ROOT/scripts/test-state-transitions" --replay-seed "$SEED" 1 >/dev/null

echo "PASS: full stack smoke"
