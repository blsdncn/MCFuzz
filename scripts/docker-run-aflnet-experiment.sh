#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${MCFUZZ_AFLNET_IMAGE:-mcfuzz-aflnet-experiment:latest}"

if [[ $# -eq 0 ]]; then
  set -- bash
fi

# Run as the invoking user so generated campaign/coverage artifacts remain editable on the host.
tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args=(-it)
fi

# Default to a repo-local Gradle cache. Auto-mounting the host ~/.gradle cache can fail with
# journal lock contention when another Gradle process is active. Opt in explicitly with:
#   MCFUZZ_DOCKER_GRADLE_HOME="$HOME/.gradle" scripts/docker-run-aflnet-experiment.sh ...
gradle_home="/work/.gradle-container"
gradle_volume_args=()
if [[ -n "${MCFUZZ_DOCKER_GRADLE_HOME:-}" ]]; then
  host_gradle_home="$MCFUZZ_DOCKER_GRADLE_HOME"
  mkdir -p "$host_gradle_home"
  gradle_home="/host-gradle-cache"
  gradle_volume_args=(--volume "$host_gradle_home:/host-gradle-cache")
fi

docker run --rm "${tty_args[@]}" \
  --init \
  --user "$(id -u):$(id -g)" \
  --workdir /work \
  --volume "$ROOT:/work" \
  "${gradle_volume_args[@]}" \
  --env HOME=/work/.container-home \
  --env GRADLE_USER_HOME="$gradle_home" \
  --env NPM_CONFIG_CACHE=/work/.npm-cache-container \
  --env AFL_NO_UI=1 \
  --env AFL_SKIP_CPUFREQ=1 \
  --env AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
  --env AFL_NO_AFFINITY=1 \
  "$IMAGE" \
  "$@"
