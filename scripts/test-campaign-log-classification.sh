#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

run_case() {
  local name="$1"
  local process_status="$2"
  local velocity_log="$TMPDIR/$name.velocity.log"
  local backend_log="$TMPDIR/$name.backend.log"
  local aflnet_log="$TMPDIR/$name.aflnet.log"
  mkdir -p "$(dirname "$velocity_log")"
  : >"$velocity_log"
  : >"$backend_log"
  : >"$aflnet_log"
  cat >"$velocity_log"
  cat >"$backend_log"
  cat >"$aflnet_log"
  VELOCITY_PROCESS_STATUS="$process_status" \
    "$ROOT/scripts/classify-campaign-logs.sh" "$velocity_log" "$backend_log" "$aflnet_log" \
    >"$TMPDIR/$name.summary"
}

assert_field() {
  local summary="$1"
  local key="$2"
  local expected="$3"
  grep -qx "$key=$expected" "$summary" || {
    echo "Expected $key=$expected in $summary" >&2
    cat "$summary" >&2
    exit 1
  }
}

# clean run
: >"$TMPDIR/clean.velocity.log"
: >"$TMPDIR/clean.backend.log"
: >"$TMPDIR/clean.aflnet.log"
VELOCITY_PROCESS_STATUS=alive "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/clean.velocity.log" "$TMPDIR/clean.backend.log" "$TMPDIR/clean.aflnet.log" \
  >"$TMPDIR/clean.summary"
assert_field "$TMPDIR/clean.summary" velocity_process_status alive
assert_field "$TMPDIR/clean.summary" velocity_process_death no
assert_field "$TMPDIR/clean.summary" velocity_fatal_exception_count 0
assert_field "$TMPDIR/clean.summary" target_failure_class clean

# handled client/protocol rejection is not a target crash
cat >"$TMPDIR/handled.velocity.log" <<'LOG'
[initial connection] /127.0.0.1:35054 provided invalid protocol 61
[connected player] SeedBot (/127.0.0.1:35994): disconnected while connecting to lobby: An internal server connection error occurred.
LOG
: >"$TMPDIR/handled.backend.log"
: >"$TMPDIR/handled.aflnet.log"
VELOCITY_PROCESS_STATUS=alive "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/handled.velocity.log" "$TMPDIR/handled.backend.log" "$TMPDIR/handled.aflnet.log" \
  >"$TMPDIR/handled.summary"
assert_field "$TMPDIR/handled.summary" velocity_fatal_exception_count 0
assert_field "$TMPDIR/handled.summary" handled_client_exception_count 2
assert_field "$TMPDIR/handled.summary" target_failure_class handled-rejections

# backend/session errors increase broad fatal-ish logs but not strict fatal target crashes
cat >"$TMPDIR/session.velocity.log" <<'LOG'
[server connection] SeedBot -> lobby: exception encountered in com.velocitypowered.proxy.connection.backend.ConfigSessionHandler@a3af842
java.lang.ClassCastException: class ClientPlaySessionHandler cannot be cast to class ClientConfigSessionHandler
[connected player] SeedBot has disconnected: Unable to connect to lobby: An internal server connection error occurred.
LOG
: >"$TMPDIR/session.backend.log"
: >"$TMPDIR/session.aflnet.log"
VELOCITY_PROCESS_STATUS=alive "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/session.velocity.log" "$TMPDIR/session.backend.log" "$TMPDIR/session.aflnet.log" \
  >"$TMPDIR/session.summary"
assert_field "$TMPDIR/session.summary" velocity_fatal_exception_count 0
assert_field "$TMPDIR/session.summary" backend_or_session_error_count 3
assert_field "$TMPDIR/session.summary" target_failure_class handled-rejections
# broad fatal_velocity_log_count is intentionally broader than strict fatal exceptions.
grep -Eq '^fatal_velocity_log_count=[1-9][0-9]*$' "$TMPDIR/session.summary"

# timeout-heavy beats handled rejections but not fatal logs.
for i in $(seq 1 10); do echo "operation timeout $i"; done >"$TMPDIR/timeout.aflnet.log"
echo "[initial connection] /127.0.0.1 provided invalid protocol 9" >"$TMPDIR/timeout.velocity.log"
: >"$TMPDIR/timeout.backend.log"
VELOCITY_PROCESS_STATUS=alive "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/timeout.velocity.log" "$TMPDIR/timeout.backend.log" "$TMPDIR/timeout.aflnet.log" \
  >"$TMPDIR/timeout.summary"
assert_field "$TMPDIR/timeout.summary" handled_client_exception_count 1
assert_field "$TMPDIR/timeout.summary" timeout_count 10
assert_field "$TMPDIR/timeout.summary" target_failure_class timeout-heavy

# connection resets and timeouts are distinct.
for i in $(seq 1 10); do echo "write ECONNRESET $i"; done >"$TMPDIR/reset.backend.log"
for i in $(seq 1 3); do echo "poll timeout $i"; done >"$TMPDIR/reset.aflnet.log"
: >"$TMPDIR/reset.velocity.log"
VELOCITY_PROCESS_STATUS=alive "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/reset.velocity.log" "$TMPDIR/reset.backend.log" "$TMPDIR/reset.aflnet.log" \
  >"$TMPDIR/reset.summary"
assert_field "$TMPDIR/reset.summary" connection_reset_count 10
assert_field "$TMPDIR/reset.summary" timeout_count 3
assert_field "$TMPDIR/reset.summary" target_failure_class connection-reset-heavy

# fatal/unhandled Velocity exception beats timeout-heavy.
cat >"$TMPDIR/fatal.velocity.log" <<'LOG'
Exception in thread "main" java.lang.RuntimeException: boom
LOG
for i in $(seq 1 10); do echo "operation timeout $i"; done >"$TMPDIR/fatal.aflnet.log"
: >"$TMPDIR/fatal.backend.log"
VELOCITY_PROCESS_STATUS=alive "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/fatal.velocity.log" "$TMPDIR/fatal.backend.log" "$TMPDIR/fatal.aflnet.log" \
  >"$TMPDIR/fatal.summary"
assert_field "$TMPDIR/fatal.summary" velocity_fatal_exception_count 1
assert_field "$TMPDIR/fatal.summary" target_failure_class fatal-log

# process death beats fatal-log.
VELOCITY_PROCESS_STATUS=exited "$ROOT/scripts/classify-campaign-logs.sh" \
  "$TMPDIR/fatal.velocity.log" "$TMPDIR/fatal.backend.log" "$TMPDIR/fatal.aflnet.log" \
  >"$TMPDIR/process-death.summary"
assert_field "$TMPDIR/process-death.summary" velocity_process_status exited
assert_field "$TMPDIR/process-death.summary" velocity_process_death yes
assert_field "$TMPDIR/process-death.summary" target_failure_class process-death

echo "PASS: campaign log classification"
