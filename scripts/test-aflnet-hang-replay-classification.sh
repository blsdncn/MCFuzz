#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RUN_DIR="$TMPDIR/run"
HANG_DIR="$RUN_DIR/aflnet-out/replayable-hangs"
mkdir -p "$HANG_DIR"

printf 'hang-one' >"$HANG_DIR/id:000001,hang"
printf 'hang-two' >"$HANG_DIR/id:000002,hang"
printf 'hang-three' >"$HANG_DIR/id:000003,hang"
touch -d @1000 "$HANG_DIR/id:000001,hang"
touch -d @1010 "$HANG_DIR/id:000002,hang"
touch -d @1020 "$HANG_DIR/id:000003,hang"

FAKE_REPLAYER="$TMPDIR/fake-replayer.sh"
cat >"$FAKE_REPLAYER" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$(basename "$1")" in
  id:000001,hang)
    echo 'Size of the current packet 1 is  17' >&2
    echo 'Responses from server:0-' >&2
    exit 0
    ;;
  id:000002,hang)
    echo 'Size of the current packet 1 is  5' >&2
    echo '[AFLNet-replay] No server response captured' >&2
    exit 8
    ;;
  id:000003,hang)
    echo 'Size of the current packet 1 is  9' >&2
    echo 'Size of the current packet 2 is  4' >&2
    echo 'Responses from server:1-2-' >&2
    exit 139
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_REPLAYER"

AFLNET_HANG_REPLAYER="$FAKE_REPLAYER" \
AFLNET_HANG_REPLAY_SKIP_TARGET_CHECK=1 \
AFLNET_HANG_REPLAY_TIMEOUT_SECONDS=2 \
  "$ROOT/scripts/classify-aflnet-hang-replays.sh" "$RUN_DIR" 3 >/dev/null

OUT="$RUN_DIR/hang-replay-classification.txt"
[[ -s "$OUT" ]] || { echo "hang replay classification missing" >&2; exit 1; }

assert_field() {
  local key="$1"
  local expected="$2"
  grep -qx "$key=$expected" "$OUT" || {
    echo "Expected $key=$expected" >&2
    cat "$OUT" >&2
    exit 1
  }
}

assert_field hang_replay_classification_status PASS
assert_field hang_replay_mode sample-replay
assert_field replay_sample_requested 3
assert_field replay_sample_count 3
assert_field replay_success_count 1
assert_field replay_timeout_count 0
assert_field replay_nonzero_count 2
assert_field replay_sigsegv_count 1
assert_field replay_no_response_exit_count 1
assert_field replay_response_sequence_count 2
assert_field replay_initial_only_response_count 1
assert_field replay_no_response_sequence_count 1
assert_field replay_distinct_response_sequences 2
assert_field target_reachable_after_replay skipped
assert_field hang_replay_interpretation replayer-crash-sample

grep -Fq 'sample_1_file=id:000001,hang' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_2_file=id:000002,hang' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_3_file=id:000003,hang' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_1_packet_count=1' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_1_response_sequence=0-' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_2_exit=8' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_2_class=no-response' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_2_packet_count=1' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_2_response_sequence=unavailable' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_3_exit=139' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_3_class=replayer-sigsegv' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_3_packet_count=2' "$OUT" || { cat "$OUT" >&2; exit 1; }
grep -Fq 'sample_3_response_sequence=1-2-' "$OUT" || { cat "$OUT" >&2; exit 1; }

RUN_DIR2="$TMPDIR/run-ephemeral"
HANG_DIR2="$RUN_DIR2/aflnet-out/replayable-hangs"
mkdir -p "$HANG_DIR2"
printf 'success-one' >"$HANG_DIR2/id:000001,hang"
printf 'success-two' >"$HANG_DIR2/id:000002,hang"

SUCCESS_REPLAYER="$TMPDIR/success-replayer.sh"
cat >"$SUCCESS_REPLAYER" <<'SUCCESS'
#!/usr/bin/env bash
set -euo pipefail
echo 'Size of the current packet 1 is  17' >&2
echo 'Responses from server:0-' >&2
exit 0
SUCCESS
chmod +x "$SUCCESS_REPLAYER"

AFLNET_HANG_REPLAYER="$SUCCESS_REPLAYER" \
AFLNET_HANG_REPLAY_TARGET_REACHABLE_OVERRIDE=yes \
AFLNET_HANG_REPLAY_TIMEOUT_SECONDS=2 \
  "$ROOT/scripts/classify-aflnet-hang-replays.sh" "$RUN_DIR2" 2 >/dev/null

OUT2="$RUN_DIR2/hang-replay-classification.txt"
grep -qx 'replay_success_count=2' "$OUT2" || { cat "$OUT2" >&2; exit 1; }
grep -qx 'replay_response_sequence_count=2' "$OUT2" || { cat "$OUT2" >&2; exit 1; }
grep -qx 'target_reachable_after_replay=yes' "$OUT2" || { cat "$OUT2" >&2; exit 1; }
grep -qx 'hang_replay_interpretation=ephemeral-not-reproduced-by-sample' "$OUT2" || { cat "$OUT2" >&2; exit 1; }

echo "PASS: AFLNet hang replay classification"
