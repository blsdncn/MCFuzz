#!/usr/bin/env bash
set -euo pipefail

DETAILS_DIR=""
if [[ $# -ge 2 && "${1:-}" == "--details-dir" ]]; then
  [[ $# -eq 4 ]] || { echo "usage: $0 [--details-dir <dir>] <baseline-jacoco.xml> <campaign-jacoco.xml>" >&2; exit 2; }
  DETAILS_DIR="$2"
  shift 2
fi

if [[ $# -ne 2 ]]; then
  echo "usage: $0 [--details-dir <dir>] <baseline-jacoco.xml> <campaign-jacoco.xml>" >&2
  exit 2
fi

BASELINE_XML="$1"
CAMPAIGN_XML="$2"
[[ -s "$BASELINE_XML" ]] || { echo "missing baseline JaCoCo XML: $BASELINE_XML" >&2; exit 2; }
[[ -s "$CAMPAIGN_XML" ]] || { echo "missing campaign JaCoCo XML: $CAMPAIGN_XML" >&2; exit 2; }

python3 - "$BASELINE_XML" "$CAMPAIGN_XML" "$DETAILS_DIR" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

baseline = Path(sys.argv[1])
campaign = Path(sys.argv[2])
details_dir_arg = sys.argv[3]
COUNTERS = ["INSTRUCTION", "BRANCH", "LINE", "METHOD", "CLASS"]

def class_line_covered(class_node):
    for counter_node in class_node.findall("counter[@type='LINE']"):
        if int(counter_node.attrib.get("covered", "0")) > 0:
            return True
    return False

def percent(covered, total):
    if total == 0:
        return "0.0000"
    return f"{(covered * 100.0 / total):.4f}"

def parse_line_locations(root):
    instrumented = set()
    covered = set()
    missed_only = set()
    for package_node in root.findall("package"):
        package_name = package_node.attrib.get("name", "")
        for source_node in package_node.findall("sourcefile"):
            source_name = source_node.attrib.get("name", "")
            if not source_name:
                continue
            prefix = f"{package_name}/{source_name}" if package_name else source_name
            for line_node in source_node.findall("line"):
                nr = line_node.attrib.get("nr")
                if not nr:
                    continue
                mi = int(line_node.attrib.get("mi", "0"))
                ci = int(line_node.attrib.get("ci", "0"))
                if mi + ci <= 0:
                    continue
                loc = f"{prefix}:{nr}"
                instrumented.add(loc)
                if ci > 0:
                    covered.add(loc)
                else:
                    missed_only.add(loc)
    return instrumented, covered, missed_only

def parse(path):
    root = ET.parse(path).getroot()
    result = {}
    for kind in COUNTERS:
        missed = 0
        covered = 0
        for node in root.findall(f"counter[@type='{kind}']"):
            missed += int(node.attrib.get("missed", "0"))
            covered += int(node.attrib.get("covered", "0"))
        result[kind.lower()] = {"missed": missed, "covered": covered, "total": missed + covered}

    covered_classes = set()
    covered_packages = set()
    for package_node in root.findall("package"):
        package_name = package_node.attrib.get("name", "")
        for class_node in package_node.findall("class"):
            class_name = class_node.attrib.get("name", "")
            if class_name and class_line_covered(class_node):
                covered_classes.add(class_name)
                covered_packages.add(package_name)

    instrumented_lines, covered_lines, missed_only_lines = parse_line_locations(root)
    return result, covered_classes, covered_packages, instrumented_lines, covered_lines, missed_only_lines

def write_lines(path, lines):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{line}\n" for line in sorted(lines)))

b, baseline_classes, baseline_packages, baseline_instrumented_lines, baseline_covered_lines, baseline_missed_only_lines = parse(baseline)
c, campaign_classes, campaign_packages, campaign_instrumented_lines, campaign_covered_lines, campaign_missed_only_lines = parse(campaign)
if not any(v["covered"] > 0 for v in b.values()):
    raise SystemExit("baseline JaCoCo XML has no covered counters")
if not any(v["covered"] > 0 for v in c.values()):
    raise SystemExit("campaign JaCoCo XML has no covered counters")

classes_both = baseline_classes & campaign_classes
classes_campaign_only = campaign_classes - baseline_classes
classes_baseline_only = baseline_classes - campaign_classes
packages_both = baseline_packages & campaign_packages
packages_campaign_only = campaign_packages - baseline_packages
packages_baseline_only = baseline_packages - campaign_packages

lines_both = baseline_covered_lines & campaign_covered_lines
lines_campaign_only = campaign_covered_lines - baseline_covered_lines
lines_baseline_only = baseline_covered_lines - campaign_covered_lines
lines_union = baseline_covered_lines | campaign_covered_lines

if details_dir_arg:
    details_dir = Path(details_dir_arg)
    write_lines(details_dir / "baseline-covered-lines.txt", baseline_covered_lines)
    write_lines(details_dir / "campaign-covered-lines.txt", campaign_covered_lines)
    write_lines(details_dir / "covered-by-both-lines.txt", lines_both)
    write_lines(details_dir / "campaign-only-covered-lines.txt", lines_campaign_only)
    write_lines(details_dir / "baseline-only-covered-lines.txt", lines_baseline_only)
    write_lines(details_dir / "baseline-missed-only-lines.txt", baseline_missed_only_lines)
    write_lines(details_dir / "campaign-missed-only-lines.txt", campaign_missed_only_lines)

print("comparison_status=PASS")
print("comparison_tool=jacoco")
print(f"baseline_report_xml={baseline}")
print(f"campaign_report_xml={campaign}")
print("comparison_scope=coarse-counters-class-package-and-line-location-deltas")
print("comparison_thresholds=none")
if details_dir_arg:
    print(f"line_details_dir={details_dir_arg}")
else:
    print("line_details_dir=not-requested")
for kind in [k.lower() for k in COUNTERS]:
    print(f"baseline_{kind}_missed={b[kind]['missed']}")
    print(f"baseline_{kind}_covered={b[kind]['covered']}")
    print(f"baseline_{kind}_total={b[kind]['total']}")
    print(f"campaign_{kind}_missed={c[kind]['missed']}")
    print(f"campaign_{kind}_covered={c[kind]['covered']}")
    print(f"campaign_{kind}_total={c[kind]['total']}")
    print(f"{kind}_covered_delta={c[kind]['covered'] - b[kind]['covered']}")

print(f"baseline_classes_with_covered_lines={len(baseline_classes)}")
print(f"campaign_classes_with_covered_lines={len(campaign_classes)}")
print(f"classes_covered_by_both={len(classes_both)}")
print(f"classes_covered_by_campaign_not_baseline={len(classes_campaign_only)}")
print(f"classes_covered_by_baseline_not_campaign={len(classes_baseline_only)}")
print(f"baseline_packages_with_covered_lines={len(baseline_packages)}")
print(f"campaign_packages_with_covered_lines={len(campaign_packages)}")
print(f"packages_covered_by_both={len(packages_both)}")
print(f"packages_covered_by_campaign_not_baseline={len(packages_campaign_only)}")
print(f"packages_covered_by_baseline_not_campaign={len(packages_baseline_only)}")

print(f"baseline_line_locations_instrumented={len(baseline_instrumented_lines)}")
print(f"baseline_line_locations_covered={len(baseline_covered_lines)}")
print(f"baseline_line_locations_missed_only={len(baseline_missed_only_lines)}")
print(f"baseline_line_location_coverage_percent={percent(len(baseline_covered_lines), len(baseline_instrumented_lines))}")
print(f"campaign_line_locations_instrumented={len(campaign_instrumented_lines)}")
print(f"campaign_line_locations_covered={len(campaign_covered_lines)}")
print(f"campaign_line_locations_missed_only={len(campaign_missed_only_lines)}")
print(f"campaign_line_location_coverage_percent={percent(len(campaign_covered_lines), len(campaign_instrumented_lines))}")
print(f"line_locations_covered_by_both={len(lines_both)}")
print(f"line_locations_covered_by_campaign_not_baseline={len(lines_campaign_only)}")
print(f"line_locations_covered_by_baseline_not_campaign={len(lines_baseline_only)}")
print(f"line_locations_covered_union={len(lines_union)}")
print(f"line_location_coverage_delta={len(campaign_covered_lines) - len(baseline_covered_lines)}")
PY
