#!/usr/bin/env bash
set -euo pipefail

ROOT="${PRIME_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

"$ROOT/scripts/setup-prismarine-deps.sh"
"$ROOT/scripts/build-required-artifacts.sh"

echo "prime_status=PASS"
