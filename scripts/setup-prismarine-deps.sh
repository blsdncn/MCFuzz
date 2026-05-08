#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NPM_INSTALL_ARGS_DEFAULT="--no-package-lock"
NPM_INSTALL_ARGS="${NPM_INSTALL_ARGS:-$NPM_INSTALL_ARGS_DEFAULT}"

install_package() {
  local rel="$1"
  local dir="$ROOT/$rel"
  [[ -f "$dir/package.json" ]] || { echo "missing package.json: $rel" >&2; exit 2; }
  echo "[prismarine] npm install $NPM_INSTALL_ARGS in $rel"
  (
    cd "$dir"
    # shellcheck disable=SC2086
    npm install $NPM_INSTALL_ARGS
  )
}

# Required by scripts/generate-seed.js and scripts/generate-variants.js.
install_package "prismarinejs/node-minecraft-protocol"

# Required backend for scripts/run-stack-smoke.sh and scripts/run-aflnet-campaign-smoke.sh.
install_package "prismarinejs/flying-squid"

echo "prismarine_deps_status=PASS"
