#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <candidate-csv> <output-dir> [limit]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_CSV="$1"
OUT_DIR="$2"
LIMIT="${3:-0}"
AFL_INCLUDE="${AFL_INCLUDE:-com.velocitypowered.*}"
AFL_EXCLUDE="${AFL_EXCLUDE:-com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket}"
REPLAY_TIMEOUT_SECONDS="${AFLNET_HANG_REPLAY_TIMEOUT_SECONDS:-10}"
FIRST_RESPONSE_TIMEOUT="${AFLNET_HANG_REPLAY_FIRST_RESPONSE_TIMEOUT:-1}"
FOLLOWUP_RESPONSE_TIMEOUT="${AFLNET_HANG_REPLAY_FOLLOWUP_RESPONSE_TIMEOUT:-1000}"
NODE_PATH_PREFIX="${MCFUZZ_NODE_PATH_PREFIX:-$HOME/.nvm/versions/node/v24.14.1/bin}"
export PATH="$NODE_PATH_PREFIX:$PATH"

[[ -f "$CANDIDATE_CSV" ]] || { echo "missing candidate csv: $CANDIDATE_CSV" >&2; exit 2; }
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "limit must be numeric" >&2; exit 2; }

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing required file: $path" >&2; exit 2; }
}

require_file "$ROOT/aflnet/aflnet-replay"
require_file "$ROOT/afl-mc-agent/build/libs/afl-mc-agent-3.5.0-SNAPSHOT.jar"
require_file "$ROOT/velocity/proxy/build/libs/velocity-proxy-3.5.0-SNAPSHOT-all.jar"
require_file "$ROOT/prismarinejs/flying-squid/app.js"

TMPDIR="$(mktemp -d)"
RUN_DIR="$TMPDIR/targeted-run"
HANG_DIR="$RUN_DIR/aflnet-out/replayable-hangs"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$HANG_DIR" "$LOG_DIR" "$OUT_DIR"

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

python3 - "$CANDIDATE_CSV" "$HANG_DIR" "$OUT_DIR/selected-candidates.txt" "$LIMIT" <<'PY'
import csv, sys, shutil
from pathlib import Path
csv_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
manifest = Path(sys.argv[3])
limit = int(sys.argv[4])
seen = set()
selected = []
with csv_path.open() as f:
    reader = csv.DictReader(f)
    for row in reader:
        p = row.get('path', '').strip()
        if not p or p in seen:
            continue
        seen.add(p)
        selected.append((row.get('group', 'unknown'), Path(p)))
if limit > 0:
    selected = selected[:limit]
for group, src in selected:
    if not src.is_file():
        continue
    shutil.copy2(src, out_dir / src.name)
manifest.write_text('\n'.join(f"{group},{src}" for group, src in selected) + ('\n' if selected else ''))
print(len(selected))
PY

CANDIDATE_COUNT="$(wc -l < "$OUT_DIR/selected-candidates.txt" | tr -d ' ')"
[[ "$CANDIDATE_COUNT" -gt 0 ]] || { echo "no candidates selected" >&2; exit 2; }

kill_port 25565
kill_port 30066
wait_for_port_free 25565 || { echo "port 25565 still busy" >&2; exit 7; }
wait_for_port_free 30066 || { echo "port 30066 still busy" >&2; exit 8; }

(
  cd "$ROOT/prismarinejs/flying-squid"
  nohup node app.js >"$LOG_DIR/flying-squid.log" 2>&1 &
  echo $! > "$TMPDIR/flying-squid.pid"
)
wait_for_port 30066 || { echo "flying-squid failed to start" >&2; cat "$LOG_DIR/flying-squid.log" >&2; exit 3; }

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
  nohup "${java_cmd[@]}" >"$LOG_DIR/velocity.log" 2>&1 &
  echo $! > "$TMPDIR/velocity.pid"
)
wait_for_port 25565 || { echo "Velocity failed to start" >&2; cat "$LOG_DIR/velocity.log" >&2; exit 4; }

sleep 1

AFLNET_HANG_REPLAY_PROTOCOL=MC \
AFLNET_HANG_REPLAY_PORT=25565 \
AFLNET_HANG_REPLAY_FIRST_RESPONSE_TIMEOUT="$FIRST_RESPONSE_TIMEOUT" \
AFLNET_HANG_REPLAY_FOLLOWUP_RESPONSE_TIMEOUT="$FOLLOWUP_RESPONSE_TIMEOUT" \
AFLNET_HANG_REPLAY_TIMEOUT_SECONDS="$REPLAY_TIMEOUT_SECONDS" \
"$ROOT/scripts/classify-aflnet-hang-replays.sh" "$RUN_DIR" "$CANDIDATE_COUNT" >/dev/null

cp "$RUN_DIR/hang-replay-classification.txt" "$OUT_DIR/"
cp -R "$RUN_DIR/hang-replay-logs" "$OUT_DIR/"
cp "$LOG_DIR/velocity.log" "$OUT_DIR/replay-target-velocity.log"
cp "$LOG_DIR/flying-squid.log" "$OUT_DIR/replay-target-flying-squid.log"
cat >"$OUT_DIR/README.md" <<EOF
# Targeted Hang Replay Triage

candidate_csv=$CANDIDATE_CSV
selected_candidates=$OUT_DIR/selected-candidates.txt
candidate_count=$CANDIDATE_COUNT
replay_timeout_seconds=$REPLAY_TIMEOUT_SECONDS
first_response_timeout=$FIRST_RESPONSE_TIMEOUT
followup_response_timeout=$FOLLOWUP_RESPONSE_TIMEOUT
velocity_log=$OUT_DIR/replay-target-velocity.log
backend_log=$OUT_DIR/replay-target-flying-squid.log
classification=$OUT_DIR/hang-replay-classification.txt
EOF

echo "TARGETED_HANG_REPLAY_TRIAGE=$OUT_DIR"
