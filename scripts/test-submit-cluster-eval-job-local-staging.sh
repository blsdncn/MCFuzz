#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$REPO_TMP"' EXIT

FAKEBIN="$TMP/fakebin"
JOB_ROOT="$TMP/jobs"
REPO_TMP="$ROOT/.tmp-test-submit-local-staging-$$"
EVAL_RUN_ROOT="$REPO_TMP/eval-runs"
mkdir -p "$FAKEBIN" "$JOB_ROOT" "$EVAL_RUN_ROOT"

cat >"$FAKEBIN/sbatch" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >"$TMP/sbatch-args.txt"
echo 999999
EOF
chmod +x "$FAKEBIN/sbatch"

BASELINE_XML="$ROOT/eval-runs/20260503T042725Z-state-aware-600s/velocity-jacoco-baseline/jacoco.xml"
[[ -f "$BASELINE_XML" ]] || { echo "missing baseline fixture: $BASELINE_XML" >&2; exit 2; }

PATH="$FAKEBIN:$PATH" \
CLUSTER_JOB_ROOT="$JOB_ROOT" \
EVAL_RUN_ROOT="$EVAL_RUN_ROOT" \
EVAL_RUN_ID="test-local-stage" \
AFLNET_FEEDBACK_MODE="state-aware" \
CAMPAIGN_SECONDS="3600" \
RUN_BASELINE="0" \
BASELINE_XML="$BASELINE_XML" \
JACOCO_WINDOW_MODE="campaign-epoch" \
CLUSTER_APPTAINER_IMAGE="/u/uyk5kn/mcfuzz/containers/aflnet-experiment-light.sif" \
"$ROOT/scripts/submit-cluster-eval-job.sh" >"$TMP/out.txt"

SBATCH_SCRIPT="$JOB_ROOT/test-local-stage.sbatch"
[[ -f "$SBATCH_SCRIPT" ]] || { echo "missing sbatch script: $SBATCH_SCRIPT" >&2; exit 1; }

grep -F 'SLURM_TMPDIR' "$SBATCH_SCRIPT" >/dev/null || { echo "expected local scratch staging" >&2; exit 1; }
grep -F 'rsync -a --delete' "$SBATCH_SCRIPT" >/dev/null || { echo "expected rsync-based staging/sync" >&2; exit 1; }
grep -F 'run-cluster-apptainer.sh' "$SBATCH_SCRIPT" >/dev/null || { echo "expected container launch from generated script" >&2; exit 1; }
grep -F 'trap cleanup EXIT' "$SBATCH_SCRIPT" >/dev/null || { echo "expected exit trap cleanup sync" >&2; exit 1; }
grep -F 'CLUSTER_APPTAINER_IMAGE=' "$SBATCH_SCRIPT" >/dev/null || { echo "expected explicit shared image path" >&2; exit 1; }
grep -F 'eval-runs/test-local-stage' "$SBATCH_SCRIPT" >/dev/null || { echo "expected targeted eval-run sync path" >&2; exit 1; }
grep -F 'JACOCO_WINDOW_MODE=campaign-epoch' "$SBATCH_SCRIPT" >/dev/null || { echo "expected JACOCO_WINDOW_MODE passthrough" >&2; exit 1; }

echo "PASS: submit-cluster-eval-job local staging script generation"
