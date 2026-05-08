#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <campaign-run-dir>" >&2
  exit 2
fi

RUN_DIR="$1"
HANG_DIR="$RUN_DIR/aflnet-out/replayable-hangs"
OUT="$RUN_DIR/hang-analysis.txt"

iso_time() {
  local ts="$1"
  if [[ "$ts" =~ ^[0-9]+$ && "$ts" -gt 0 ]]; then
    date -u -d "@$ts" '+%Y-%m-%dT%H:%M:%SZ'
  else
    echo unavailable
  fi
}

if [[ ! -d "$HANG_DIR" ]]; then
  {
    echo "hang_analysis_status=PASS"
    echo "hang_analysis_mode=artifact-only-not-replayed"
    echo "replayable_hang_count=0"
    echo "unique_hang_hash_count=0"
    echo "duplicate_hang_count=0"
    echo "hang_size_min=0"
    echo "hang_size_max=0"
    echo "first_hang_artifact_time=unavailable"
    echo "last_hang_artifact_time=unavailable"
    echo "sample_hang_files="
    echo "hang_interpretation=artifact-only-not-replayed"
  } >"$OUT"
  echo "HANG_ANALYSIS=$OUT"
  exit 0
fi

python3 - "$HANG_DIR" "$OUT" <<'PY'
import sys, hashlib, datetime
from pathlib import Path
hang_dir=Path(sys.argv[1])
out=Path(sys.argv[2])
files=sorted([p for p in hang_dir.iterdir() if p.is_file()], key=lambda p: (p.stat().st_mtime, p.name))
if not files:
    out.write_text('\n'.join([
        'hang_analysis_status=PASS',
        'hang_analysis_mode=artifact-only-not-replayed',
        'replayable_hang_count=0',
        'unique_hang_hash_count=0',
        'duplicate_hang_count=0',
        'hang_size_min=0',
        'hang_size_max=0',
        'first_hang_artifact_time=unavailable',
        'last_hang_artifact_time=unavailable',
        'sample_hang_files=',
        'hang_interpretation=artifact-only-not-replayed',
    ]) + '\n')
    raise SystemExit
sizes=[p.stat().st_size for p in files]
hashes=[]
for p in files:
    h=hashlib.sha256(p.read_bytes()).hexdigest()
    hashes.append(h)
unique=len(set(hashes))
fmt=lambda ts: datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
# Sample first two and last two unique names by time, preserving order.
sample=[]
for p in files[:2] + files[-2:]:
    if p.name not in sample:
        sample.append(p.name)
lines=[
    'hang_analysis_status=PASS',
    'hang_analysis_mode=artifact-only-not-replayed',
    f'replayable_hang_count={len(files)}',
    f'unique_hang_hash_count={unique}',
    f'duplicate_hang_count={len(files)-unique}',
    f'hang_size_min={min(sizes)}',
    f'hang_size_max={max(sizes)}',
    f'first_hang_artifact_time={fmt(files[0].stat().st_mtime)}',
    f'last_hang_artifact_time={fmt(files[-1].stat().st_mtime)}',
    'sample_hang_files=' + ','.join(sample),
    'hang_interpretation=artifact-only-not-replayed',
]
out.write_text('\n'.join(lines) + '\n')
PY

echo "HANG_ANALYSIS=$OUT"
