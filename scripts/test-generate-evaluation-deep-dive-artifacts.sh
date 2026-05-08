#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EVAL_ROOT="$TMP/eval-runs"
OUT_ROOT="$TMP/out"
mkdir -p "$EVAL_ROOT" "$OUT_ROOT"

python3 - "$EVAL_ROOT" <<'PY'
from pathlib import Path
import sys
EVAL=Path(sys.argv[1])
runs=[
    ("20260503T054121Z-state-aware-43200s","state-aware",True),
    ("20260503T054505Z-code-only-43200s","code-only",True),
    ("20260503T054506Z-state-only-43200s","state-only",True),
    ("20260505T045009Z-state-aware-86400s","state-aware",True),
    ("20260503T045624Z-state-aware-86400s","state-aware",False),
]
for slug, mode, clean in runs:
    root=EVAL/slug
    campaign=root/'campaign'
    afl=campaign/'aflnet-out'
    q=afl/'queue'
    rh=afl/'replayable-hangs'
    sp=afl/'replayable-new-ipsm-paths'
    ld=campaign/'coverage'/'line-details'
    logs=campaign/'logs'
    for d in [q,rh,sp,ld,logs]: d.mkdir(parents=True, exist_ok=True)
    (root/'eval-summary.txt').write_text('eval_status=PASS\n')
    (campaign/'run-summary.txt').write_text('\n'.join([
        'campaign_status=PASS',
        f'campaign_seconds={86400 if "86400" in slug else 43200}',
        f'aflnet_feedback_mode={mode}',
        'queue_paths_found=1',
        'execs_done=100',
        'execs_per_sec=1.0',
        'state_coverage_nodes=3' if mode != 'code-only' else 'state_coverage_nodes=0',
        'state_coverage_edges=2' if mode != 'code-only' else 'state_coverage_edges=0',
        'afl_fuzz_bitmap_changed_cells=3',
        'edge_coverage_nonzero_cells=4',
        'target_failure_class=clean',
        'velocity_alive_after_campaign=yes',
    ])+'\n')
    (campaign/'coverage'/'comparison-vs-latest-baseline.txt').parent.mkdir(parents=True, exist_ok=True)
    (campaign/'coverage'/'comparison-vs-latest-baseline.txt').write_text('\n'.join([
        'line_covered_delta=10',
        'campaign_line_locations_covered=20',
        'classes_covered_by_campaign_not_baseline=2',
        'packages_covered_by_campaign_not_baseline=1',
        'campaign_line_location_coverage_percent=10.0',
    ])+'\n')
    (campaign/'hang-analysis.txt').write_text('\n'.join([
        'replayable_hang_count=2',
        'unique_hang_hash_count=2',
        'duplicate_hang_count=0',
        'hang_size_min=4',
        'hang_size_max=8',
        'first_hang_artifact_time=2026-01-01T00:00:00Z',
        'last_hang_artifact_time=2026-01-01T00:10:00Z',
    ])+'\n')
    (afl/'fuzzer_stats').write_text('\n'.join([
        'start_time        : 1000',
        'last_update       : 4600',
        'execs_done        : 100',
        'execs_per_sec     : 1.0',
        'paths_total       : 2',
        'paths_found       : 1',
        'bitmap_cvg        : 1.00%',
        'unique_crashes    : 0',
        'unique_hangs      : 0',
        'last_path         : 4600',
    ])+'\n')
    (afl/'plot_data').write_text('\n'.join([
        '1000,0,0,1,1,0,1.00%,0,0,1,1.00,2,1',
        '4600,1,0,2,1,0,1.20%,0,0,2,1.50,3,2',
    ])+'\n')
    (q/'id:000000,orig:handshake-only.bin').write_bytes(b'abc')
    (q/'id:000001,src:000000,op:havoc,rep:4,+cov').write_bytes(b'abcdef')
    (rh/'id:000000,src:000000,op:havoc,rep:2').write_bytes(b'xxxx')
    (rh/'id:000001,src:000000,op:havoc,rep:4').write_bytes(b'yyyyyy')
    (sp/'id:0-1:id:000001,orig:handshake-only.bin').write_text('')
    if mode != 'code-only':
        (afl/'ipsm.dot').write_text('digraph g {\n  0 [color=blue];\n  1 [color=blue];\n  2 [color=red];\n  0 -> 1 [color=blue];\n  1 -> 2 [color=red];\n}\n')
    (logs/'velocity.log').write_text('[00:00:01 ERROR]: [server connection] TestBot -> lobby: exception encountered in x\njava.lang.IllegalStateException: bad thing 127.0.0.1:25565\n    at com.example.Test.foo(Test.java:1)\n')
    (logs/'flying-squid.log').write_text('')
    (logs/'aflnet.log').write_text('connection reset by peer\n')
    for name, lines in {
        'campaign-covered-lines.txt':['com/velocitypowered/proxy/connection/Foo.java:10','com/velocitypowered/proxy/protocol/Bar.java:20'],
        'campaign-only-covered-lines.txt':['com/velocitypowered/proxy/connection/Foo.java:10'],
        'baseline-covered-lines.txt':['com/velocitypowered/api/Baz.java:1'],
        'covered-by-both-lines.txt':['com/velocitypowered/proxy/protocol/Bar.java:20'],
        'baseline-only-covered-lines.txt':['com/velocitypowered/api/Baz.java:1'],
        'baseline-missed-only-lines.txt':['com/velocitypowered/api/Baz.java:2'],
        'campaign-missed-only-lines.txt':['com/velocitypowered/proxy/connection/Foo.java:11'],
    }.items():
        (ld/name).write_text('\n'.join(lines)+'\n')
PY

DEEP_DIVE_EVAL_ROOT="$EVAL_ROOT" \
DEEP_DIVE_OUTPUT_ROOT="$OUT_ROOT" \
python3 "$ROOT/scripts/generate-evaluation-deep-dive-artifacts.py"

[[ -f "$OUT_ROOT/tables/queue-size-summary.csv" ]] || { echo "missing queue-size-summary.csv" >&2; exit 1; }
[[ -f "$OUT_ROOT/tables/state-machine-summary.csv" ]] || { echo "missing state-machine-summary.csv" >&2; exit 1; }
[[ -f "$OUT_ROOT/tables/exception-signature-summary.csv" ]] || { echo "missing exception-signature-summary.csv" >&2; exit 1; }
[[ -f "$OUT_ROOT/investigation-report.md" ]] || { echo "missing investigation-report.md" >&2; exit 1; }

grep -q '12h state+coverage,state-aware,2,3,4.5,4.5,6' "$OUT_ROOT/tables/queue-size-summary.csv" || { echo "queue summary missing expected row" >&2; cat "$OUT_ROOT/tables/queue-size-summary.csv" >&2; exit 1; }
grep -q '12h state+coverage,3,2,0' "$OUT_ROOT/tables/state-machine-summary.csv" || { echo "state machine summary missing expected nodes/edges" >&2; cat "$OUT_ROOT/tables/state-machine-summary.csv" >&2; exit 1; }
grep -q 'java.lang.IllegalStateException' "$OUT_ROOT/tables/exception-signature-summary.csv" || { echo "exception signature summary missing expected exception" >&2; cat "$OUT_ROOT/tables/exception-signature-summary.csv" >&2; exit 1; }

echo "PASS: generate evaluation deep dive artifacts"
