#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <campaign-run-dir> [sample-count]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$1"
REQUESTED_SAMPLE_COUNT="${2:-5}"
HANG_DIR="$RUN_DIR/aflnet-out/replayable-hangs"
OUT="$RUN_DIR/hang-replay-classification.txt"
LOG_DIR="$RUN_DIR/hang-replay-logs"
REPLAYER="${AFLNET_HANG_REPLAYER:-$ROOT/aflnet/aflnet-replay}"
PROTOCOL="${AFLNET_HANG_REPLAY_PROTOCOL:-MC}"
PORT="${AFLNET_HANG_REPLAY_PORT:-25565}"
FIRST_RESPONSE_TIMEOUT="${AFLNET_HANG_REPLAY_FIRST_RESPONSE_TIMEOUT:-1}"
FOLLOWUP_RESPONSE_TIMEOUT="${AFLNET_HANG_REPLAY_FOLLOWUP_RESPONSE_TIMEOUT:-1000}"
WRAPPER_TIMEOUT_SECONDS="${AFLNET_HANG_REPLAY_TIMEOUT_SECONDS:-10}"
SKIP_TARGET_CHECK="${AFLNET_HANG_REPLAY_SKIP_TARGET_CHECK:-0}"
TARGET_REACHABLE_OVERRIDE="${AFLNET_HANG_REPLAY_TARGET_REACHABLE_OVERRIDE:-}"

[[ "$REQUESTED_SAMPLE_COUNT" =~ ^[0-9]+$ ]] || { echo "sample-count must be numeric" >&2; exit 2; }
[[ "$WRAPPER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || { echo "AFLNET_HANG_REPLAY_TIMEOUT_SECONDS must be numeric" >&2; exit 2; }
[[ -x "$REPLAYER" ]] || { echo "missing executable replayer: $REPLAYER" >&2; exit 2; }
mkdir -p "$LOG_DIR"

iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

select_samples() {
  python3 - "$HANG_DIR" "$REQUESTED_SAMPLE_COUNT" <<'PY'
import sys
from pathlib import Path
hang_dir=Path(sys.argv[1])
count=int(sys.argv[2])
if count <= 0 or not hang_dir.is_dir():
    raise SystemExit
files=sorted([p for p in hang_dir.iterdir() if p.is_file()], key=lambda p: (p.stat().st_mtime, p.name))
if len(files) <= count:
    chosen=files
elif count <= 2:
    chosen=[files[0], files[-1]][:count]
else:
    first_count=(count + 2)//3
    middle_count=(count + 1)//3
    last_count=count//3
    middle_start=max(first_count, (len(files) - middle_count)//2)
    middle_end=min(len(files) - last_count, middle_start + middle_count)
    chosen=files[:first_count] + files[middle_start:middle_end] + files[-last_count:]
    seen=set(); dedup=[]
    for p in chosen:
        if p not in seen:
            seen.add(p); dedup.append(p)
    chosen=dedup[:count]
for p in chosen:
    print(str(p))
PY
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

target_reachable() {
  if [[ -n "$TARGET_REACHABLE_OVERRIDE" ]]; then
    echo "$TARGET_REACHABLE_OVERRIDE"
    return 0
  fi
  if [[ "$SKIP_TARGET_CHECK" == "1" ]]; then
    echo skipped
    return 0
  fi
  if ss -tln | grep -q ":$PORT "; then
    echo yes
  else
    echo no
  fi
}

map_exit_class() {
  local rc="$1"
  if [[ "$rc" -eq 0 ]]; then
    echo success
  elif [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo timeout
  elif [[ "$rc" -eq 139 ]]; then
    echo replayer-sigsegv
  elif [[ "$rc" -eq 7 ]]; then
    echo malformed-replay
  elif [[ "$rc" -eq 8 ]]; then
    echo no-response
  elif [[ "$rc" -eq 9 ]]; then
    echo send-failed
  elif [[ "$rc" -eq 10 ]]; then
    echo recv-failed
  else
    echo nonzero
  fi
}

sample_files=()
if [[ -d "$HANG_DIR" ]]; then
  while IFS= read -r sample; do
    [[ -n "$sample" ]] && sample_files+=("$sample")
  done < <(select_samples)
fi

success_count=0
timeout_count=0
nonzero_count=0
sigsegv_count=0
malformed_replay_count=0
no_response_exit_count=0
send_failed_count=0
recv_failed_count=0
response_sequence_count=0
initial_only_response_count=0
no_response_sequence_count=0
response_sequences=()
per_sample_lines=()
idx=0
for sample in "${sample_files[@]}"; do
  idx=$((idx + 1))
  base="$(basename "$sample")"
  log="$LOG_DIR/$(printf '%02d' "$idx")-$(safe_name "$base").log"
  start=$(date +%s)
  set +e
  AFLNET_REPLAY_STRICT=1 timeout "$WRAPPER_TIMEOUT_SECONDS" "$REPLAYER" "$sample" "$PROTOCOL" "$PORT" "$FIRST_RESPONSE_TIMEOUT" "$FOLLOWUP_RESPONSE_TIMEOUT" >"$log" 2>&1
  rc=$?
  set -e
  end=$(date +%s)
  cls="$(map_exit_class "$rc")"
  packet_count="$(grep -c 'Size of the current packet' "$log" 2>/dev/null || true)"
  response_sequence="$(python3 - "$log" <<'PY'
import re, sys
text=open(sys.argv[1], errors='replace').read()
m=re.search(r'Responses from server:([^\n]*)', text)
if not m:
    print('unavailable')
else:
    seq=m.group(1).strip()
    print(seq if seq else 'empty')
PY
)"
  if [[ "$response_sequence" == "unavailable" ]]; then
    no_response_sequence_count=$((no_response_sequence_count + 1))
  else
    response_sequence_count=$((response_sequence_count + 1))
    response_sequences+=("$response_sequence")
    if [[ "$response_sequence" == "0-" || "$response_sequence" == "0" ]]; then
      initial_only_response_count=$((initial_only_response_count + 1))
    fi
  fi
  case "$cls" in
    success) success_count=$((success_count + 1)) ;;
    timeout) timeout_count=$((timeout_count + 1)) ;;
    replayer-sigsegv) sigsegv_count=$((sigsegv_count + 1)); nonzero_count=$((nonzero_count + 1)) ;;
    malformed-replay) malformed_replay_count=$((malformed_replay_count + 1)); nonzero_count=$((nonzero_count + 1)) ;;
    no-response) no_response_exit_count=$((no_response_exit_count + 1)); nonzero_count=$((nonzero_count + 1)) ;;
    send-failed) send_failed_count=$((send_failed_count + 1)); nonzero_count=$((nonzero_count + 1)) ;;
    recv-failed) recv_failed_count=$((recv_failed_count + 1)); nonzero_count=$((nonzero_count + 1)) ;;
    nonzero) nonzero_count=$((nonzero_count + 1)) ;;
  esac
  per_sample_lines+=("sample_${idx}_file=$base")
  per_sample_lines+=("sample_${idx}_exit=$rc")
  per_sample_lines+=("sample_${idx}_class=$cls")
  per_sample_lines+=("sample_${idx}_duration_seconds=$((end - start))")
  per_sample_lines+=("sample_${idx}_packet_count=$packet_count")
  per_sample_lines+=("sample_${idx}_response_sequence=$response_sequence")
  per_sample_lines+=("sample_${idx}_log=$log")
done

reachable="$(target_reachable)"
sample_count="${#sample_files[@]}"
distinct_response_sequences=0
if [[ "${#response_sequences[@]}" -gt 0 ]]; then
  distinct_response_sequences="$(printf '%s\n' "${response_sequences[@]}" | sort -u | wc -l | tr -d ' ')"
fi
if [[ "$sample_count" -eq 0 ]]; then
  interpretation="no-hangs"
elif [[ "$reachable" == "no" ]]; then
  interpretation="target-not-reachable-after-replay"
elif [[ "$timeout_count" -gt 0 && "$success_count" -eq 0 && "$nonzero_count" -eq 0 ]]; then
  interpretation="reproduced-timeout"
elif [[ "$timeout_count" -gt 0 ]]; then
  interpretation="mixed-timeout"
elif [[ "$sigsegv_count" -gt 0 ]]; then
  interpretation="replayer-crash-sample"
elif [[ "$malformed_replay_count" -gt 0 ]]; then
  interpretation="malformed-replay-sample"
elif [[ "$no_response_exit_count" -gt 0 && "$timeout_count" -eq 0 ]]; then
  interpretation="replay-no-response-sample"
elif [[ "$success_count" -eq "$sample_count" && "$response_sequence_count" -eq "$sample_count" && "$reachable" == "yes" ]]; then
  interpretation="ephemeral-not-reproduced-by-sample"
elif [[ "$success_count" -eq "$sample_count" ]]; then
  interpretation="not-reproduced-by-replay-sample"
elif [[ "$success_count" -gt 0 || "$nonzero_count" -gt 0 ]]; then
  interpretation="mixed"
else
  interpretation="unknown"
fi

{
  echo "hang_replay_classification_status=PASS"
  echo "hang_replay_mode=sample-replay"
  echo "hang_replay_started_at=$(iso_now)"
  echo "replayer=$REPLAYER"
  echo "protocol=$PROTOCOL"
  echo "port=$PORT"
  echo "wrapper_timeout_seconds=$WRAPPER_TIMEOUT_SECONDS"
  echo "replay_sample_requested=$REQUESTED_SAMPLE_COUNT"
  echo "replay_sample_count=$sample_count"
  echo "replay_success_count=$success_count"
  echo "replay_timeout_count=$timeout_count"
  echo "replay_nonzero_count=$nonzero_count"
  echo "replay_sigsegv_count=$sigsegv_count"
  echo "replay_malformed_count=$malformed_replay_count"
  echo "replay_no_response_exit_count=$no_response_exit_count"
  echo "replay_send_failed_count=$send_failed_count"
  echo "replay_recv_failed_count=$recv_failed_count"
  echo "replay_response_sequence_count=$response_sequence_count"
  echo "replay_initial_only_response_count=$initial_only_response_count"
  echo "replay_no_response_sequence_count=$no_response_sequence_count"
  echo "replay_distinct_response_sequences=$distinct_response_sequences"
  echo "target_reachable_after_replay=$reachable"
  echo "hang_replay_interpretation=$interpretation"
  for line in "${per_sample_lines[@]}"; do
    echo "$line"
  done
} >"$OUT"

echo "HANG_REPLAY_CLASSIFICATION=$OUT"
