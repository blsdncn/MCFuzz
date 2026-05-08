#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

make -C "$ROOT/aflnet" aflnet-replay >/dev/null

NO_RESPONSE_SEED="$TMPDIR/no-response.replay"
TRUNCATED_SEED="$TMPDIR/truncated.replay"
python3 - "$NO_RESPONSE_SEED" "$TRUNCATED_SEED" <<'PY'
import struct, sys
with open(sys.argv[1], 'wb') as f:
    f.write(struct.pack('<I', 1))
    f.write(b'X')
with open(sys.argv[2], 'wb') as f:
    f.write(struct.pack('<I', 4))
    f.write(b'XY')
PY

PORT_FILE="$TMPDIR/port"
python3 - "$PORT_FILE" <<'PY' &
import socket, sys
port_file=sys.argv[1]
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(1)
with open(port_file, 'w') as f:
    f.write(str(s.getsockname()[1]))
    f.flush()
conn, _ = s.accept()
try:
    conn.recv(4096)
finally:
    conn.close()
    s.close()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE")"

set +e
AFLNET_REPLAY_STRICT=1 timeout 5 "$ROOT/aflnet/aflnet-replay" "$NO_RESPONSE_SEED" MC "$PORT" 1 1000 >"$TMPDIR/no-response.log" 2>&1
NO_RESPONSE_RC=$?
set -e
wait "$SERVER_PID" 2>/dev/null || true

if [[ "$NO_RESPONSE_RC" -eq 139 ]]; then
  echo "aflnet-replay segfaulted on no-response replay" >&2
  cat "$TMPDIR/no-response.log" >&2
  exit 1
fi
[[ "$NO_RESPONSE_RC" -eq 8 ]] || {
  echo "Expected strict no-response exit 8, got $NO_RESPONSE_RC" >&2
  cat "$TMPDIR/no-response.log" >&2
  exit 1
}
grep -Fq '[AFLNet-replay] No server response captured' "$TMPDIR/no-response.log" || {
  echo "Expected no-response diagnostic" >&2
  cat "$TMPDIR/no-response.log" >&2
  exit 1
}

set +e
AFLNET_REPLAY_STRICT=1 timeout 5 "$ROOT/aflnet/aflnet-replay" "$TRUNCATED_SEED" MC 1 1 1000 >"$TMPDIR/truncated.log" 2>&1
TRUNCATED_RC=$?
set -e
if [[ "$TRUNCATED_RC" -eq 139 ]]; then
  echo "aflnet-replay segfaulted on truncated replay" >&2
  cat "$TMPDIR/truncated.log" >&2
  exit 1
fi
[[ "$TRUNCATED_RC" -eq 7 ]] || {
  echo "Expected truncated replay exit 7, got $TRUNCATED_RC" >&2
  cat "$TMPDIR/truncated.log" >&2
  exit 1
}
grep -Fq '[AFLNet-replay] Truncated packet payload' "$TMPDIR/truncated.log" || {
  echo "Expected truncated payload diagnostic" >&2
  cat "$TMPDIR/truncated.log" >&2
  exit 1
}

RESPONSE_SEED="$TMPDIR/response.replay"
python3 - "$RESPONSE_SEED" <<'PY'
import struct, sys
with open(sys.argv[1], 'wb') as f:
    f.write(struct.pack('<I', 1))
    f.write(b'X')
PY
RESPONSE_PORT_FILE="$TMPDIR/response-port"
python3 - "$RESPONSE_PORT_FILE" <<'PY' &
import socket, sys
port_file=sys.argv[1]
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(1)
with open(port_file, 'w') as f:
    f.write(str(s.getsockname()[1]))
    f.flush()
conn, _ = s.accept()
try:
    conn.recv(4096)
    conn.sendall(b'\x01\x02')
finally:
    conn.close()
    s.close()
PY
RESPONSE_SERVER_PID=$!
for _ in $(seq 1 50); do
  [[ -s "$RESPONSE_PORT_FILE" ]] && break
  sleep 0.1
done
RESPONSE_PORT="$(cat "$RESPONSE_PORT_FILE")"
set +e
AFLNET_REPLAY_STRICT=1 timeout 5 "$ROOT/aflnet/aflnet-replay" "$RESPONSE_SEED" MC "$RESPONSE_PORT" 50 1000 >"$TMPDIR/response.log" 2>&1
RESPONSE_RC=$?
set -e
wait "$RESPONSE_SERVER_PID" 2>/dev/null || true
if [[ "$RESPONSE_RC" -eq 139 ]]; then
  echo "aflnet-replay segfaulted while parsing MC response" >&2
  cat "$TMPDIR/response.log" >&2
  exit 1
fi
[[ "$RESPONSE_RC" -eq 0 ]] || {
  echo "Expected response replay exit 0, got $RESPONSE_RC" >&2
  cat "$TMPDIR/response.log" >&2
  exit 1
}
grep -Fq 'Responses from server:0-1-' "$TMPDIR/response.log" || {
  echo "Expected parsed MC response state sequence" >&2
  cat "$TMPDIR/response.log" >&2
  exit 1
}

echo "PASS: AFLNet replay hardened diagnostics"
