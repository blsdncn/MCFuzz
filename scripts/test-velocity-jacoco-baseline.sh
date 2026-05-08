#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VELOCITY_DIR="$ROOT/velocity"
RUN_ROOT="${COVERAGE_RUN_ROOT:-$ROOT/coverage-runs}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RUN_DIR="${JACOCO_BASELINE_RUN_DIR:-$RUN_ROOT/$RUN_ID/velocity-jacoco-baseline}"
LOG="$RUN_DIR/velocity-jacoco-baseline.log"
INIT_SCRIPT="$RUN_DIR/velocity-jacoco-baseline.init.gradle"
SUMMARY="$RUN_DIR/coverage-summary.txt"
XML_REPORT="$RUN_DIR/jacoco.xml"
HTML_REPORT_DIR="$RUN_DIR/html"
EXEC_DIR="$RUN_DIR/exec"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || { echo "Missing required file: $path" >&2; exit 2; }
}

fail() {
  local message="$1"
  {
    echo "coverage_status=FAIL"
    echo "reason=$message"
    echo "coverage_tool=jacoco"
    echo "coverage_subject=velocity-repo-test-suite"
    echo "coverage_scope=all-repo-main-classes"
    echo "run_dir=$RUN_DIR"
    echo "log=$LOG"
  } >"$SUMMARY" 2>/dev/null || true
  echo "FAIL: $message" >&2
  echo "RUN_DIR=$RUN_DIR" >&2
  echo "LOG=$LOG" >&2
  if [[ -f "$LOG" ]]; then
    echo "--- log tail ---" >&2
    tail -100 "$LOG" >&2 || true
  fi
  exit 1
}

require_file "$VELOCITY_DIR/gradlew"
mkdir -p "$RUN_DIR" "$EXEC_DIR" "$HTML_REPORT_DIR"

cat >"$INIT_SCRIPT" <<'EOF'
import org.gradle.api.tasks.testing.Test
import org.gradle.testing.jacoco.plugins.JacocoTaskExtension
import org.gradle.testing.jacoco.tasks.JacocoReport

allprojects { project ->
  project.plugins.apply('jacoco')
  project.jacoco.toolVersion = '0.8.14'

  project.tasks.withType(Test).configureEach { testTask ->
    def safeName = testTask.path.replace(':', '_').replaceAll('[^A-Za-z0-9_.-]', '_')
    testTask.extensions.configure(JacocoTaskExtension) { jacocoExt ->
      jacocoExt.destinationFile = new File(System.getProperty('jacocoReportDir'), "exec/${safeName}.exec")
    }
  }
}

gradle.projectsEvaluated {
  def reportDir = new File(System.getProperty('jacocoReportDir'))
  def javaProjects = rootProject.allprojects.findAll { project ->
    project.plugins.hasPlugin('java') && project.extensions.findByName('sourceSets') != null
  }
  def testTasks = javaProjects.collectMany { project -> project.tasks.withType(Test).toList() }

  rootProject.tasks.register('jacocoWholeRepoReport', JacocoReport) { reportTask ->
    reportTask.group = 'verification'
    reportTask.description = 'Generates aggregate JaCoCo report for all Velocity repo main classes.'
    reportTask.dependsOn(testTasks)
    reportTask.executionData.from(testTasks.collect { testTask ->
      testTask.extensions.getByType(JacocoTaskExtension).destinationFile
    })
    reportTask.sourceDirectories.from(javaProjects.collect { project -> project.sourceSets.main.allSource.srcDirs })
    reportTask.classDirectories.from(javaProjects.collect { project -> project.sourceSets.main.output.classesDirs })
    reportTask.reports { reports ->
      reports.xml.required = true
      reports.xml.outputLocation = new File(reportDir, 'jacoco.xml')
      reports.html.required = true
      reports.html.outputLocation = new File(reportDir, 'html')
      reports.csv.required = false
    }
  }
}
EOF

set +e
(
  cd "$VELOCITY_DIR"
  ./gradlew test jacocoWholeRepoReport \
    --offline \
    --no-daemon \
    --rerun-tasks \
    --init-script "$INIT_SCRIPT" \
    -DjacocoReportDir="$RUN_DIR"
) >"$LOG" 2>&1
gradle_exit=$?
set -e
if [[ "$gradle_exit" -ne 0 ]]; then
  echo "Offline Velocity JaCoCo baseline failed; retrying online" >>"$LOG"
  set +e
  (
    cd "$VELOCITY_DIR"
    ./gradlew test jacocoWholeRepoReport \
      --no-daemon \
      --rerun-tasks \
      --init-script "$INIT_SCRIPT" \
      -DjacocoReportDir="$RUN_DIR"
  ) >>"$LOG" 2>&1
  gradle_exit=$?
  set -e
fi

echo "$gradle_exit" >"$RUN_DIR/gradle.exit"
[[ "$gradle_exit" -eq 0 ]] || fail "velocity-tests-or-jacoco-report-failed"
[[ -s "$XML_REPORT" ]] || fail "jacoco-xml-missing"
[[ -d "$HTML_REPORT_DIR" ]] || fail "jacoco-html-missing"
[[ -n "$(find "$HTML_REPORT_DIR" -type f -print -quit)" ]] || fail "jacoco-html-empty"
[[ -n "$(find "$EXEC_DIR" -type f -name '*.exec' -print -quit)" ]] || fail "jacoco-exec-missing"

python3 - "$XML_REPORT" "$SUMMARY" "$RUN_DIR" "$LOG" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

xml_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
run_dir = Path(sys.argv[3])
log = Path(sys.argv[4])
root = ET.parse(xml_path).getroot()

def counter(counter_type):
    missed = 0
    covered = 0
    for node in root.findall(f"counter[@type='{counter_type}']"):
        missed += int(node.attrib.get('missed', '0'))
        covered += int(node.attrib.get('covered', '0'))
    return missed, covered

counters = {name: counter(name) for name in ['INSTRUCTION', 'BRANCH', 'LINE', 'METHOD', 'CLASS']}
if not any(covered > 0 for _, covered in counters.values()):
    raise SystemExit('no nonzero covered counters in JaCoCo XML')

lines = [
    'coverage_status=PASS',
    'coverage_tool=jacoco',
    'coverage_subject=velocity-repo-test-suite',
    'coverage_scope=all-repo-main-classes',
    'coverage_denominator=all compiled main classes from included Velocity Gradle projects',
    f'run_dir={run_dir}',
    f'log={log}',
    f'coverage_report_xml={xml_path}',
    f'coverage_report_html={run_dir / "html"}',
    f'coverage_exec_dir={run_dir / "exec"}',
]
for name, (missed, covered) in counters.items():
    key = name.lower()
    total = missed + covered
    percent = (covered * 100.0 / total) if total else 0.0
    lines.extend([
        f'{key}_missed={missed}',
        f'{key}_covered={covered}',
        f'{key}_total={total}',
        f'{key}_covered_percent={percent:.4f}',
    ])
summary_path.write_text('\n'.join(lines) + '\n')
PY

[[ -s "$SUMMARY" ]] || fail "coverage-summary-missing"
grep -Eq '^instruction_covered=[1-9][0-9]*$' "$SUMMARY" || fail "instruction-covered-not-positive"
grep -Eq '^line_covered=[1-9][0-9]*$' "$SUMMARY" || fail "line-covered-not-positive"

echo "RUN_DIR=$RUN_DIR"
echo "SUMMARY=$SUMMARY"
echo "PASS: Velocity JaCoCo baseline"
