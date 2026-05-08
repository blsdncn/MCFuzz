#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${MCFUZZ_AFLNET_IMAGE:-mcfuzz-aflnet-experiment:latest}"

"$ROOT/scripts/docker-build-aflnet-experiment.sh" >/tmp/mcfuzz-docker-build.log 2>&1 || {
  cat /tmp/mcfuzz-docker-build.log >&2
  exit 1
}

docker run --rm \
  --workdir /work \
  --volume "$ROOT:/work" \
  "$IMAGE" \
  bash -lc '
    set -euo pipefail
    java -version
    node --version | grep -E "^v24\."
    javac -version | grep -E "21"
    gcc --version >/dev/null
    clang --version >/dev/null
    make --version >/dev/null
    lsof -v >/dev/null 2>&1 || true
    ss -h >/dev/null
    ipcmk --help >/dev/null
    ipcrm --help >/dev/null
    python3 --version >/dev/null
    test -x scripts/run-aflnet-campaign-smoke.sh
    test -x scripts/setup-prismarine-deps.sh
    test -x scripts/build-required-artifacts.sh
    test -x scripts/run-regression-suite.sh
    test -x scripts/spike-jazzer-jacoco-feasibility.sh
    test -f Makefile
  ' >/tmp/mcfuzz-docker-smoke.log 2>&1 || {
    cat /tmp/mcfuzz-docker-smoke.log >&2
    exit 1
  }

cat /tmp/mcfuzz-docker-smoke.log
printf 'PASS: Docker AFLNet experiment image %s\n' "$IMAGE"
