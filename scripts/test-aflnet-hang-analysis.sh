#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RUN_DIR="$TMPDIR/run"
HANG_DIR="$RUN_DIR/aflnet-out/replayable-hangs"
mkdir -p "$HANG_DIR"

printf 'same-hang' >"$HANG_DIR/id:000001,hang"
printf 'same-hang' >"$HANG_DIR/id:000002,hang-duplicate"
printf 'different-hang-longer' >"$HANG_DIR/id:000003,hang"
touch -d @1000 "$HANG_DIR/id:000001,hang"
touch -d @1010 "$HANG_DIR/id:000002,hang-duplicate"
touch -d @1060 "$HANG_DIR/id:000003,hang"

"$ROOT/scripts/analyze-aflnet-hangs.sh" "$RUN_DIR" >/dev/null
OUT="$RUN_DIR/hang-analysis.txt"
[[ -s "$OUT" ]] || { echo "hang analysis missing" >&2; exit 1; }

assert_field() {
  local key="$1"
  local expected="$2"
  grep -qx "$key=$expected" "$OUT" || {
    echo "Expected $key=$expected" >&2
    cat "$OUT" >&2
    exit 1
  }
}

assert_field hang_analysis_status PASS
assert_field hang_analysis_mode artifact-only-not-replayed
assert_field replayable_hang_count 3
assert_field unique_hang_hash_count 2
assert_field duplicate_hang_count 1
assert_field hang_size_min 9
assert_field hang_size_max 21
assert_field first_hang_artifact_time 1970-01-01T00:16:40Z
assert_field last_hang_artifact_time 1970-01-01T00:17:40Z
assert_field hang_interpretation artifact-only-not-replayed

grep -Eq '^sample_hang_files=.*id:000001,hang.*id:000003,hang' "$OUT" || {
  echo "Expected sample hang files" >&2
  cat "$OUT" >&2
  exit 1
}

echo "PASS: AFLNet hang analysis"
