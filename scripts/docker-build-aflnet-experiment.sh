#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${MCFUZZ_AFLNET_IMAGE:-mcfuzz-aflnet-experiment:latest}"

cd "$ROOT"
docker build \
  -f docker/aflnet-experiment.Dockerfile \
  -t "$IMAGE" \
  docker

echo "IMAGE=$IMAGE"
