#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-${SUBMISSION_TREE:-$(cd "$ROOT/.." && pwd)/mcfuzz-submission-clean}}"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }
}

require_tool rsync
require_tool python3

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

if [[ "$DEST" == "$ROOT" || "$DEST" == "$ROOT"/* ]]; then
  echo "Refusing to create submission tree inside source root: $DEST" >&2
  exit 2
fi

EXCLUDE_FILE="$(mktemp)"
trap 'rm -f "$EXCLUDE_FILE"' EXIT

cat >"$EXCLUDE_FILE" <<'EOF'
# VCS/local agent/editor state
/.git/
**/.git/
/.pi/
/.idea/
/.vscode/
.DS_Store
*.swp
*.swo

# Build outputs and dependency caches
/.gradle-container/
.gradle/
**/.gradle/
**/build/
**/target/
**/out/
**/node_modules/
**/.pytest_cache/
**/__pycache__/
*.class
*.o
*.a
*.dll

# Generated fuzzing/evaluation runs
/campaign-runs/
/compat-runs/
/coverage-runs/
/eval-runs/
/slurm-jobs/
/.tmp-*/
/FTL/investigations/evaluation-artifact-deep-dive/jazzer-comparison/spikes/

# Runtime logs and transient outputs
/test-path-results*.log
*.pid
*.exec
*.profraw
*.profdata
hs_err_pid*.log
replay_pid*.log

# Generated AFL/AFLNet/Jazzer artifacts when outside ignored build/run dirs
aflnet-out/
queue/
crashes/
hangs/
replayable-hangs/
**/jazzer-stderr.log
**/jazzer-faults.txt
**/jazzer-artifacts.txt
**/jazzer-coverage
**/reproducer*.java
**/crash-*
**/artifact_prefix*/

# Reference-only clones not required by public submission paths
/jacoco/
/jazzer/
/picolimbo/

# Unused Prismarine reference/source trees. AFLNet smokes require only
# prismarinejs/node-minecraft-protocol and prismarinejs/flying-squid.
/prismarinejs/minecraft-data/
/prismarinejs/mineflayer/

# Report/evidence artifacts — not needed for evaluator to run workflows.
# Generated/packaged separately from submitted code.
/FTL/
/evidence-packet/
/evidence-packet.zip

# Extra docs — consolidated into single root README.
/docs/
/SUBMISSION_MANIFEST.md

# Historical scratch/local files
/100qs/
/UBIQUITOUS_LANGUAGE.md
/grill-me-loop.html
*.tmp
*.bak
*.orig
EOF

rsync -a --delete --delete-excluded --exclude-from="$EXCLUDE_FILE" "$ROOT/" "$DEST/"

# Preserve Jazzer tools jar (excluded by **/build/ glob)
mkdir -p "$DEST/velocity-jazzer-integration/build/jazzer/tools"
cp -a "$ROOT/velocity-jazzer-integration/build/jazzer/tools/jazzer-0.24.0.jar" "$DEST/velocity-jazzer-integration/build/jazzer/tools/"
cp -a "$ROOT/velocity-jazzer-integration/build/jazzer/tools/jazzer" "$DEST/velocity-jazzer-integration/build/jazzer/tools/"
cp -a "$ROOT/velocity-jazzer-integration/build/jazzer/tools/jazzer-libs.txt" "$DEST/velocity-jazzer-integration/build/jazzer/tools/"

# Initialize as a git repository
if command -v git >/dev/null 2>&1; then
  (
    cd "$DEST"
    git init
    # Remove vendored build/ rule so Jazzer tools can be tracked
    if [[ -f "$DEST/velocity-jazzer-integration/.gitignore" ]]; then
      grep -v '^build/$' "$DEST/velocity-jazzer-integration/.gitignore" > "$DEST/velocity-jazzer-integration/.gitignore.tmp"
      mv "$DEST/velocity-jazzer-integration/.gitignore.tmp" "$DEST/velocity-jazzer-integration/.gitignore"
    fi
    git add -A
    # Force-add Jazzer tools jar (parent build/ dir may still be gitignored)
    git add -f velocity-jazzer-integration/build/jazzer/tools/jazzer-0.24.0.jar velocity-jazzer-integration/build/jazzer/tools/jazzer velocity-jazzer-integration/build/jazzer/tools/jazzer-libs.txt
    git commit -m "Curated submission snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty
  )
  echo "git_repo=initialized"
  echo "git_commit=$(cd "$DEST" && git rev-parse HEAD)"
else
  echo "git_repo=skipped (git not found)"
fi

python3 - "$DEST" <<'PY'
import os, sys
from pathlib import Path
root = Path(sys.argv[1])
files = 0
size = 0
for p in root.rglob('*'):
    if p.is_file() and not p.is_symlink():
        files += 1
        size += p.stat().st_size
print(f"submission_tree={root}")
print(f"submission_files={files}")
print(f"submission_bytes={size}")
print(f"submission_size_mb={size/1024/1024:.1f}")
required = [
    'README.md', 'Makefile',
    'scripts/run-regression-suite.sh', 'scripts/setup-prismarine-deps.sh', 'scripts/build-required-artifacts.sh',
    'scripts/run-aflnet-campaign-smoke.sh', 'scripts/spike-jazzer-jacoco-feasibility.sh',
    'aflnet/afl-fuzz.c', 'afl-mc-agent/build.gradle.kts', 'velocity/README.md',
    'velocity-jazzer-integration/scripts/run-jazzer-direct.sh',
    'prismarinejs/node-minecraft-protocol/package.json',
    'prismarinejs/flying-squid/package.json',
]
missing = [r for r in required if not (root/r).exists()]
if missing:
    print('submission_status=FAIL')
    print('missing_required=' + ','.join(missing))
    sys.exit(1)
banned = [
    'campaign-runs', 'eval-runs', 'coverage-runs', 'compat-runs', '.gradle-container',
    'jacoco', 'jazzer', 'picolimbo', 'FTL', 'docs', 'SUBMISSION_MANIFEST.md',
    'grill-me-loop.html'
]
present = [b for b in banned if (root/b).exists()]
if present:
    print('submission_status=FAIL')
    print('banned_present=' + ','.join(present))
    sys.exit(1)
node_modules = list(root.glob('**/node_modules'))
if node_modules:
    print('submission_status=FAIL')
    print('node_modules_present=' + ','.join(str(p.relative_to(root)) for p in node_modules[:20]))
    sys.exit(1)
print('submission_status=PASS')
PY
