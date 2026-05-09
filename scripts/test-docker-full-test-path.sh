#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${MCFUZZ_AFLNET_IMAGE:-mcfuzz-aflnet-experiment:latest}"
JAZZER_SMOKE_TIME_LIMIT="${JAZZER_SMOKE_TIME_LIMIT:-30}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1 || [[ "${MCFUZZ_DOCKER_FORCE_BUILD:-0}" == "1" ]]; then
  "$ROOT/scripts/docker-build-aflnet-experiment.sh" >/tmp/mcfuzz-docker-build.log 2>&1 || {
    cat /tmp/mcfuzz-docker-build.log >&2
    exit 1
  }
fi

"$ROOT/scripts/docker-run-aflnet-experiment.sh" bash -lc \
  "make deps && make test && make smoke-aflnet && TIME_LIMIT=$JAZZER_SMOKE_TIME_LIMIT make smoke-jazzer-stateful && TIME_LIMIT=$JAZZER_SMOKE_TIME_LIMIT make smoke-jazzer-stateless" || {
    echo "Docker full test path failed" >&2
    exit 1
  }

echo "PASS: Docker full test path"
