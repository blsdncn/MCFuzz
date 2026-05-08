#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOB_ROOT="${CLUSTER_JOB_ROOT:-$ROOT/slurm-jobs}"
AFLNET_FEEDBACK_MODE="${AFLNET_FEEDBACK_MODE:-state-aware}"
CAMPAIGN_SECONDS="${CAMPAIGN_SECONDS:-600}"
RUN_BASELINE="${RUN_BASELINE:-1}"
BASELINE_XML="${BASELINE_XML:-}"
JACOCO_WINDOW_MODE="${JACOCO_WINDOW_MODE:-whole-process}"
PRIME_CONTAINER_DEPS="${PRIME_CONTAINER_DEPS:-1}"
EVAL_RUN_ROOT="${EVAL_RUN_ROOT:-$ROOT/eval-runs}"
EVAL_RUN_ID="${EVAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$AFLNET_FEEDBACK_MODE-${CAMPAIGN_SECONDS}s}"
SLURM_PARTITION="${SLURM_PARTITION:-cpu}"
SLURM_CONSTRAINT="${SLURM_CONSTRAINT:-skylake}"
SLURM_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-4}"
SLURM_MEM="${SLURM_MEM:-16G}"
SLURM_TIME="${SLURM_TIME:-01:00:00}"
SLURM_JOB_NAME="${SLURM_JOB_NAME:-aflnet-${AFLNET_FEEDBACK_MODE}-${CAMPAIGN_SECONDS}s}"
SLURM_EXCLUSIVE="${SLURM_EXCLUSIVE:-0}"
SLURM_EXCLUDE_NODES="${SLURM_EXCLUDE_NODES:-}"
SLURM_NODELIST="${SLURM_NODELIST:-}"
SLURM_DEPENDENCY="${SLURM_DEPENDENCY:-}"
CLUSTER_SYNC_INTERVAL_SECONDS="${CLUSTER_SYNC_INTERVAL_SECONDS:-1800}"
CLUSTER_APPTAINER_IMAGE="${CLUSTER_APPTAINER_IMAGE:-$(dirname "$ROOT")/containers/aflnet-experiment-light.sif}"

case "$AFLNET_FEEDBACK_MODE" in
  state-aware|code-only|state-only) ;;
  *) echo "unsupported AFLNET_FEEDBACK_MODE: $AFLNET_FEEDBACK_MODE" >&2; exit 2 ;;
esac

if [[ "$RUN_BASELINE" != "1" && -z "$BASELINE_XML" ]]; then
  echo "BASELINE_XML is required when RUN_BASELINE=0" >&2
  exit 2
fi

host_path_to_container() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf '%s' "$path"
  elif [[ "$path" == /work/* ]]; then
    printf '%s' "$path"
  elif [[ "$path" == "$ROOT" ]]; then
    printf '/work'
  elif [[ "$path" == "$ROOT"/* ]]; then
    printf '/work/%s' "${path#"$ROOT/"}"
  else
    echo "Path is not inside staged repo and will not be visible in Apptainer: $path" >&2
    exit 2
  fi
}

mkdir -p "$JOB_ROOT" "$EVAL_RUN_ROOT"
SBATCH_SCRIPT="$JOB_ROOT/$EVAL_RUN_ID.sbatch"
SBATCH_STDOUT="$JOB_ROOT/$EVAL_RUN_ID-%j.out"
EVAL_RUN_ROOT_IN_CONTAINER="$(host_path_to_container "$EVAL_RUN_ROOT")"
BASELINE_XML_IN_CONTAINER="$(host_path_to_container "$BASELINE_XML")"
PERSIST_EVAL_RUN_DIR="$EVAL_RUN_ROOT/$EVAL_RUN_ID"
PERSIST_BASELINE_XML="$BASELINE_XML"

CONTAINER_CMD='cd /work && '
if [[ "$PRIME_CONTAINER_DEPS" == "1" ]]; then
  CONTAINER_CMD+="scripts/prime-container-deps.sh && "
fi
printf -v CONTAINER_CMD '%sAFLNET_FEEDBACK_MODE=%q CAMPAIGN_SECONDS=%q RUN_BASELINE=%q BASELINE_XML=%q JACOCO_WINDOW_MODE=%q EVAL_RUN_ROOT=%q EVAL_RUN_ID=%q scripts/run-eval-lane.sh' \
  "$CONTAINER_CMD" \
  "$AFLNET_FEEDBACK_MODE" \
  "$CAMPAIGN_SECONDS" \
  "$RUN_BASELINE" \
  "$BASELINE_XML_IN_CONTAINER" \
  "$JACOCO_WINDOW_MODE" \
  "$EVAL_RUN_ROOT_IN_CONTAINER" \
  "$EVAL_RUN_ID"
CONTAINER_CMD_ESCAPED="$(printf '%q' "$CONTAINER_CMD")"

EXCLUSIVE_LINE=""
if [[ "$SLURM_EXCLUSIVE" == "1" ]]; then
  EXCLUSIVE_LINE="#SBATCH --exclusive"
fi
EXCLUDE_LINE=""
if [[ -n "$SLURM_EXCLUDE_NODES" ]]; then
  EXCLUDE_LINE="#SBATCH --exclude=$SLURM_EXCLUDE_NODES"
fi
NODELIST_LINE=""
if [[ -n "$SLURM_NODELIST" ]]; then
  NODELIST_LINE="#SBATCH --nodelist=$SLURM_NODELIST"
fi
DEPENDENCY_LINE=""
if [[ -n "$SLURM_DEPENDENCY" ]]; then
  DEPENDENCY_LINE="#SBATCH --dependency=$SLURM_DEPENDENCY"
fi

cat >"$SBATCH_SCRIPT" <<EOF
#!/bin/bash
#SBATCH --job-name=$SLURM_JOB_NAME
#SBATCH --partition=$SLURM_PARTITION
#SBATCH --constraint=$SLURM_CONSTRAINT
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=$SLURM_CPUS_PER_TASK
#SBATCH --mem=$SLURM_MEM
#SBATCH --time=$SLURM_TIME
#SBATCH --output=$SBATCH_STDOUT
$EXCLUSIVE_LINE
$EXCLUDE_LINE
$NODELIST_LINE
$DEPENDENCY_LINE
set -euo pipefail
PERSIST_ROOT="$ROOT"
LOCAL_PARENT="\${SLURM_TMPDIR:-/tmp/\\${USER:-user}/\\${SLURM_JOB_ID:-$$}}"
LOCAL_ROOT="\$LOCAL_PARENT/$(basename "$ROOT")"
PERSIST_EVAL_RUN_DIR="$PERSIST_EVAL_RUN_DIR"
LOCAL_EVAL_RUN_DIR="\$LOCAL_ROOT/${PERSIST_EVAL_RUN_DIR#"$ROOT/"}"
PERSIST_BASELINE_XML="$PERSIST_BASELINE_XML"
LOCAL_BASELINE_XML=""
SYNC_INTERVAL_SECONDS="$CLUSTER_SYNC_INTERVAL_SECONDS"
SYNC_PID=""
mkdir -p "\$LOCAL_PARENT" "$(dirname "$PERSIST_EVAL_RUN_DIR")"

sync_eval_run() {
  [[ -d "\$LOCAL_EVAL_RUN_DIR" ]] || return 0
  mkdir -p "$(dirname "$PERSIST_EVAL_RUN_DIR")"
  rsync -a "\$LOCAL_EVAL_RUN_DIR/" "$PERSIST_EVAL_RUN_DIR/"
}

cleanup() {
  local status=\$?
  set +e
  if [[ -n "\$SYNC_PID" ]]; then
    kill "\$SYNC_PID" 2>/dev/null || true
    wait "\$SYNC_PID" 2>/dev/null || true
  fi
  sync_eval_run || true
  exit "\$status"
}
trap cleanup EXIT

echo started_at=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo hostname=\$(hostname)
echo slurm_job_id=\${SLURM_JOB_ID:-unavailable}
echo slurm_job_name=\${SLURM_JOB_NAME:-unavailable}
echo slurm_job_partition=\${SLURM_JOB_PARTITION:-unavailable}
echo slurm_job_nodelist=\${SLURM_JOB_NODELIST:-unavailable}
echo slurm_cpus_per_task=\${SLURM_CPUS_PER_TASK:-unavailable}
echo slurm_mem_per_node=\${SLURM_MEM_PER_NODE:-unavailable}
echo local_parent=\$LOCAL_PARENT
echo local_root=\$LOCAL_ROOT

echo [stage] syncing repo into node-local scratch
rsync -a --delete \
  --exclude 'eval-runs/' \
  --exclude 'campaign-runs/' \
  --exclude 'coverage-runs/' \
  --exclude 'compat-runs/' \
  --exclude 'FTL/' \
  --exclude 'slurm-jobs/' \
  --exclude '.tmp-test-submit-local-staging-*' \
  "\$PERSIST_ROOT/" "\$LOCAL_ROOT/"

if [[ -n "\$PERSIST_BASELINE_XML" ]]; then
  LOCAL_BASELINE_XML="\$LOCAL_ROOT/${PERSIST_BASELINE_XML#"$ROOT/"}"
  mkdir -p "\$(dirname "\$LOCAL_BASELINE_XML")"
  cp "\$PERSIST_BASELINE_XML" "\$LOCAL_BASELINE_XML"
fi

if [[ "\$SYNC_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && [[ "\$SYNC_INTERVAL_SECONDS" -gt 0 ]]; then
  (
    while true; do
      sleep "\$SYNC_INTERVAL_SECONDS"
      sync_eval_run || true
    done
  ) &
  SYNC_PID=\$!
fi

cd "\$LOCAL_ROOT"
CMD=$CONTAINER_CMD_ESCAPED
echo container_command="\$CMD"
CLUSTER_APPTAINER_IMAGE="$CLUSTER_APPTAINER_IMAGE" \
  srun --cpu-bind=cores "\$LOCAL_ROOT/scripts/run-cluster-apptainer.sh" bash -lc "\$CMD"
EOF

chmod +x "$SBATCH_SCRIPT"
JOB_ID="$(sbatch --parsable "$SBATCH_SCRIPT")"

echo "JOB_ID=$JOB_ID"
echo "SBATCH_SCRIPT=$SBATCH_SCRIPT"
echo "SBATCH_STDOUT_TEMPLATE=$SBATCH_STDOUT"
echo "EVAL_RUN_ID=$EVAL_RUN_ID"
echo "EVAL_RUN_ROOT=$EVAL_RUN_ROOT"
