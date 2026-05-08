#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_DIR="$(dirname "$ROOT")"
IMG="${CLUSTER_APPTAINER_IMAGE:-$BASE_DIR/containers/aflnet-experiment-light.sif}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <command...>" >&2
  exit 2
fi

[[ -d "$ROOT" ]] || { echo "missing cluster repo root: $ROOT" >&2; exit 2; }
[[ -f "$IMG" ]] || { echo "missing Apptainer image: $IMG" >&2; exit 2; }

type module >/dev/null 2>&1 || source /etc/profile.d/modules.sh
module load apptainer/1.3.6

ENV_LIST="GRADLE_USER_HOME=/work/.gradle-container,NPM_CONFIG_CACHE=/work/.npm-cache-container,AFL_NO_UI=1,AFL_SKIP_CPUFREQ=1,AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1,AFL_NO_AFFINITY=1"
for name in SLURM_JOB_ID SLURM_JOB_NAME SLURM_JOB_PARTITION SLURM_JOB_NODELIST SLURM_CPUS_PER_TASK SLURM_JOB_CPUS_PER_NODE SLURM_MEM_PER_NODE SLURM_MEM_PER_CPU SLURM_SUBMIT_DIR; do
  if [[ -n "${!name:-}" ]]; then
    ENV_LIST+=",$name=${!name}"
  fi
done

printf -v CMD '%q ' "$@"
exec apptainer exec \
  --cleanenv \
  --env "$ENV_LIST" \
  --bind "$ROOT:/work" \
  --pwd /work \
  "$IMG" \
  bash --noprofile --norc -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; $CMD"
