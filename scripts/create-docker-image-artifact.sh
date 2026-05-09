#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${MCFUZZ_AFLNET_IMAGE:-mcfuzz-aflnet-experiment:latest}"
RELEASE_DIR="${MCFUZZ_RELEASE_DIR:-$ROOT/release-artifacts}"
STAMP="${MCFUZZ_RELEASE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
SAFE_IMAGE="${IMAGE//[:\/]/-}"
OUT="$RELEASE_DIR/${SAFE_IMAGE}-${STAMP}.tar.gz"

mkdir -p "$RELEASE_DIR"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image not found; building $IMAGE"
  MCFUZZ_AFLNET_IMAGE="$IMAGE" "$ROOT/scripts/docker-build-aflnet-experiment.sh"
fi

echo "Saving Docker image: $IMAGE"
echo "Output: $OUT"
docker save "$IMAGE" | gzip -n > "$OUT"
(
  cd "$RELEASE_DIR"
  sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)
docker image inspect "$IMAGE" > "$OUT.inspect.json"

cat > "$RELEASE_DIR/README-docker-image-artifact.md" <<EOF
# Docker image release artifact

This directory contains a prebuilt Docker image for the MCFuzz/AFLNet/Velocity toolchain.

## Files

- $(basename "$OUT"): compressed Docker image archive
- $(basename "$OUT").sha256: SHA-256 checksum
- $(basename "$OUT").inspect.json: Docker image metadata

## Load image

\`\`\`bash
sha256sum -c $(basename "$OUT").sha256
gunzip -c $(basename "$OUT") | docker load
\`\`\`

## Use image with the repository

From the repository root:

\`\`\`bash
scripts/test-docker-full-test-path.sh
\`\`\`

The loaded image tag is:

\`\`\`text
$IMAGE
\`\`\`
EOF

printf 'artifact=%s\n' "$OUT"
printf 'checksum=%s.sha256\n' "$OUT"
printf 'metadata=%s.inspect.json\n' "$OUT"
