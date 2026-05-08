#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <velocity.log> <backend.log> <aflnet.log>" >&2
  exit 2
fi

VELOCITY_LOG="$1"
BACKEND_LOG="$2"
AFLNET_LOG="$3"
PROCESS_STATUS="${VELOCITY_PROCESS_STATUS:-unknown}"

count_log_pattern() {
  local pattern="$1"
  shift
  cat "$@" 2>/dev/null | grep -Eci "$pattern" || true
}

classify_target_failure() {
  local process_status="$1"
  local fatal_exceptions="$2"
  local handled_client_exceptions="$3"
  local resets="$4"
  local timeouts="$5"
  local backend_or_session_errors="$6"

  if [[ "$process_status" == "exited" ]]; then
    echo "process-death"
  elif [[ "$fatal_exceptions" -gt 0 ]]; then
    echo "fatal-log"
  elif [[ "$resets" -ge 10 ]]; then
    echo "connection-reset-heavy"
  elif [[ "$timeouts" -ge 10 ]]; then
    echo "timeout-heavy"
  elif [[ "$handled_client_exceptions" -gt 0 || "$backend_or_session_errors" -gt 0 ]]; then
    echo "handled-rejections"
  elif [[ "$process_status" == "alive" ]]; then
    echo "clean"
  else
    echo "unknown"
  fi
}

process_death="no"
if [[ "$PROCESS_STATUS" == "exited" ]]; then
  process_death="yes"
fi

fatal_velocity_log_count="$(count_log_pattern 'fatal|uncaught|exception|LinkageError|ClassFormatError|VerifyError' "$VELOCITY_LOG")"
velocity_fatal_exception_count="$(count_log_pattern 'Exception in thread|Uncaught|FATAL|LinkageError|ClassFormatError|VerifyError|OutOfMemoryError|StackOverflowError' "$VELOCITY_LOG")"
handled_client_exception_count="$(count_log_pattern '\[initial connection\].*provided invalid protocol|\[connected player\].*(disconnected while connecting|has disconnected)|malformed|bad packet' "$VELOCITY_LOG")"
backend_or_session_error_count="$(count_log_pattern '\[server connection\].*exception encountered|ClassCastException|internal server connection error|Unable to connect to lobby|backend' "$VELOCITY_LOG" "$BACKEND_LOG")"
connection_reset_count="$(count_log_pattern 'ECONNRESET|connection reset|Connection reset' "$AFLNET_LOG" "$VELOCITY_LOG" "$BACKEND_LOG")"
timeout_count="$(count_log_pattern 'timeout|timed out' "$AFLNET_LOG" "$VELOCITY_LOG" "$BACKEND_LOG")"
target_failure_class="$(classify_target_failure "$PROCESS_STATUS" "$velocity_fatal_exception_count" "$handled_client_exception_count" "$connection_reset_count" "$timeout_count" "$backend_or_session_error_count")"

cat <<EOF
fatal_velocity_log_count=$fatal_velocity_log_count
velocity_process_status=$PROCESS_STATUS
velocity_process_death=$process_death
velocity_fatal_exception_count=$velocity_fatal_exception_count
handled_client_exception_count=$handled_client_exception_count
connection_reset_count=$connection_reset_count
timeout_count=$timeout_count
backend_or_session_error_count=$backend_or_session_error_count
target_failure_class=$target_failure_class
EOF
