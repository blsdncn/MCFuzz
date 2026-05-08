#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/build/jazzer-stateless"
ARTIFACTS_DIR="${WORK_DIR}/artifacts"
LOG_DIR="${WORK_DIR}/logs"
CORPUS_DIR="${WORK_DIR}/corpus"
COVERAGE_DIR="${WORK_DIR}/coverage"
TARGET_CLASS="${TARGET_CLASS:-com.velocitypowered.proxy.fuzz.VelocityProtocolStateless}"
TIME_LIMIT="${TIME_LIMIT:-21600}"
JAZZER_JAR="${JAZZER_JAR:-${ROOT_DIR}/build/jazzer/tools/jazzer-0.24.0.jar}"
GRADLE_MODULE_CACHE="${GRADLE_MODULE_CACHE:-${HOME}/.gradle/caches/modules-2/files-2.1}"
RESET_OUTPUTS="${RESET_OUTPUTS:-1}"

mkdir -p "${ARTIFACTS_DIR}" "${LOG_DIR}" "${CORPUS_DIR}" "${COVERAGE_DIR}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error: required tool "%s" is not installed or not on PATH\n' "$1" >&2
    exit 1
  fi
}

require_tool "python3"
require_tool "java"
require_tool "sort"

if [ ! -f "${JAZZER_JAR}" ]; then
  printf 'error: Jazzer jar not found at %s\n' "${JAZZER_JAR}" >&2
  exit 1
fi

if [ ! -f "${ROOT_DIR}/proxy/build/classes/java/test/com/velocitypowered/proxy/fuzz/VelocityProtocolStateless.class" ]; then
  printf 'error: fuzz target class is missing in proxy/build/classes/java/test\n' >&2
  printf 'hint: run ./gradlew :velocity-proxy:testClasses once before this script\n' >&2
  exit 1
fi

if [ "${RESET_OUTPUTS}" = "1" ]; then
  rm -rf "${ARTIFACTS_DIR}" "${LOG_DIR}" "${COVERAGE_DIR}" "${CORPUS_DIR}"
  mkdir -p "${ARTIFACTS_DIR}" "${LOG_DIR}" "${COVERAGE_DIR}" "${CORPUS_DIR}"
fi

DICT_FILE="${WORK_DIR}/keywords.dict"
cat >"${DICT_FILE}" <<'EOF'
"floodgate:skin"
"minecraft:brand"
"velocity:player_info"
"bungeecord:main"
"minecraft:stone"
"minecraft:overworld"
"\x00\x00\x00\x00"
"\xff\xff\xff\xff"
EOF

SEED_SCRIPT="${ROOT_DIR}/scripts/jazzer-seed-corpus-stateless.py"
if [ -f "${SEED_SCRIPT}" ]; then
  printf '[1/8] Seeding stateless corpus with Velocity issue-inspired inputs...\n'
  python3 "${SEED_SCRIPT}"
else
  printf '[1/8] Seed script missing, keeping existing corpus...\n'
fi

printf '[2/8] Building classpath from compiled classes + Gradle cache...\n'
CLASSPATH_RAW="$(python3 - <<'PY' "${ROOT_DIR}" "${GRADLE_MODULE_CACHE}"
from pathlib import Path
import sys

root = Path(sys.argv[1])
jar_root = Path(sys.argv[2])
entries = []

for rel in (
    'proxy/build/classes/java/main',
    'proxy/build/resources/main',
    'proxy/build/classes/java/test',
    'proxy/build/resources/test',
    'api/build/classes/java/main',
    'api/build/resources/main',
    'native/build/classes/java/main',
    'native/build/resources/main',
):
    path = root / rel
    if path.exists():
        entries.append(str(path))

if jar_root.exists():
    entries.extend(str(path) for path in sorted(jar_root.rglob('*.jar')))

print(':'.join(entries))
PY
)"

if [ -z "${CLASSPATH_RAW}" ]; then
  printf 'error: computed classpath is empty\n' >&2
  exit 1
fi

printf '[3/8] Running Jazzer target %s ...\n' "${TARGET_CLASS}"
JAZZER_STDOUT_LOG="${LOG_DIR}/jazzer-stdout.log"
JAZZER_STDERR_LOG="${LOG_DIR}/jazzer-stderr.log"
JAZZER_INSTRUMENTATION_LOG="${LOG_DIR}/jazzer-instrumentation.log"

set +e
java -cp "${JAZZER_JAR}:${CLASSPATH_RAW}" com.code_intelligence.jazzer.Jazzer \
  --target_class="${TARGET_CLASS}" \
  --reproducer_path="${ARTIFACTS_DIR}" \
  --coverage_report="${COVERAGE_DIR}/jazzer-coverage" \
  --coverage_report=lcov:"${COVERAGE_DIR}/jazzer-coverage.lcov" \
  --dump_classes_dir="${WORK_DIR}/instrumented" \
  --keep_going=128 \
  -- \
  "${CORPUS_DIR}" \
  -artifact_prefix="${ARTIFACTS_DIR}/" \
  -max_total_time="${TIME_LIMIT}" \
  -rss_limit_mb=4096 \
  -print_final_stats=1 \
  -use_value_profile=1 \
  -dict="${DICT_FILE}" \
  -prefer_small=0 \
  -max_len=131072 \
  -reload=0 \
  1>"${JAZZER_STDOUT_LOG}" 2>"${JAZZER_STDERR_LOG}"
JAZZER_EXIT=$?
set -e

printf '[5/8] Extracting fault signatures...\n'
FAULTS_FILE="${LOG_DIR}/jazzer-faults.txt"
python3 - <<'PY' "${JAZZER_STDOUT_LOG}" "${JAZZER_STDERR_LOG}" "${FAULTS_FILE}"
import re
import sys

stdout_path, stderr_path, out_path = sys.argv[1:4]
patterns = [
    re.compile(r'^==\d+==\s*ERROR:.*'),
    re.compile(r'^== Java Exception:.*'),
    re.compile(r'^\s*Caused by:\s+.*'),
    re.compile(r'^\s*at\s+.*\(.*\)$'),
    re.compile(r'.*\b(FATAL|AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer)\b.*'),
    re.compile(r'.*\b(Signal\s+\d+|Segmentation fault|Illegal instruction|Aborted)\b.*', re.IGNORECASE),
    re.compile(r'^DEDUP_TOKEN:.*'),
    re.compile(r'^artifact_prefix=.*'),
    re.compile(r'^reproducer_path=.*'),
]

lines = []
for path in (stdout_path, stderr_path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                line = raw.rstrip('\n')
                if any(p.match(line) for p in patterns):
                    lines.append(line)
    except FileNotFoundError:
        pass

seen = set()
ordered = []
for line in lines:
    if line not in seen:
        seen.add(line)
        ordered.append(line)

with open(out_path, 'w', encoding='utf-8') as out:
    if not ordered:
        out.write('No crash signatures were detected in Jazzer logs.\n')
    else:
        for line in ordered:
            out.write(line + '\n')
PY

printf '[6/8] Listing produced artifacts...\n'
ARTIFACT_LIST_FILE="${LOG_DIR}/jazzer-artifacts.txt"
if [ -d "${ARTIFACTS_DIR}" ]; then
  ls -1 "${ARTIFACTS_DIR}" | sort >"${ARTIFACT_LIST_FILE}"
else
  : >"${ARTIFACT_LIST_FILE}"
fi

python3 - <<'PY' "${JAZZER_STDERR_LOG}" "${JAZZER_INSTRUMENTATION_LOG}"
import re
import sys

src, out = sys.argv[1:3]
pattern = re.compile(r'^INFO: Instrumented com\.velocitypowered\..*')
rows = []
with open(src, 'r', encoding='utf-8', errors='replace') as fh:
    for line in fh:
        line = line.rstrip('\n')
        if pattern.match(line):
            rows.append(line)

with open(out, 'w', encoding='utf-8') as fh:
    for row in sorted(dict.fromkeys(rows)):
        fh.write(row + '\n')
PY

printf '[7/7] Writing run summary...\n'
SUMMARY_FILE="${WORK_DIR}/summary.txt"
{
  printf 'Jazzer run summary\n'
  printf 'target class: %s\n' "${TARGET_CLASS}"
  printf 'run mode: direct java invocation with cache-derived classpath (single pass)\n'
  printf 'run time(s): %s\n' "${TIME_LIMIT}"
  printf 'exit code: %s\n' "${JAZZER_EXIT}"
  printf 'stdout log: %s\n' "${JAZZER_STDOUT_LOG}"
  printf 'stderr log: %s\n' "${JAZZER_STDERR_LOG}"
  printf 'instrumentation log: %s\n' "${JAZZER_INSTRUMENTATION_LOG}"
  printf 'fault report: %s\n' "${FAULTS_FILE}"
  printf 'artifact list: %s\n' "${ARTIFACT_LIST_FILE}"
  printf 'coverage report quick: %s\n' "${COVERAGE_DIR}/jazzer-coverage"
} >"${SUMMARY_FILE}"

printf 'done. Summary: %s\n' "${SUMMARY_FILE}"
printf 'fault signatures: %s\n' "${FAULTS_FILE}"
printf 'artifacts: %s\n' "${ARTIFACT_LIST_FILE}"

# Jazzer exit 1 means findings found — expected behavior, not an error.
if [[ "$JAZZER_EXIT" -eq 1 ]]; then
  JAZZER_EXIT=0
fi

exit "${JAZZER_EXIT}"
