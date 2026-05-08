#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${MCFUZZ_AFLNET_IMAGE:-mcfuzz-aflnet-experiment:latest}"

"$ROOT/scripts/docker-build-aflnet-experiment.sh" >/tmp/mcfuzz-docker-build.log 2>&1 || {
  cat /tmp/mcfuzz-docker-build.log >&2
  exit 1
}

"$ROOT/scripts/docker-run-aflnet-experiment.sh" bash -lc \
  "make deps && make test" || {
    echo "Docker full test path failed" >&2
    exit 1
  }

echo "PASS: Docker full test path"
