#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BASELINE="$TMPDIR/baseline.xml"
CAMPAIGN="$TMPDIR/campaign.xml"
DETAILS="$TMPDIR/details"
OUT="$TMPDIR/comparison.txt"

cat >"$BASELINE" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<report name="baseline">
  <package name="pkg">
    <class name="pkg/A" sourcefilename="A.java">
      <counter type="LINE" missed="1" covered="2"/>
    </class>
    <sourcefile name="A.java">
      <line nr="1" mi="0" ci="1" mb="0" cb="0"/>
      <line nr="2" mi="0" ci="1" mb="0" cb="0"/>
      <line nr="3" mi="1" ci="0" mb="0" cb="0"/>
      <counter type="LINE" missed="1" covered="2"/>
    </sourcefile>
    <counter type="LINE" missed="1" covered="2"/>
  </package>
  <counter type="INSTRUCTION" missed="1" covered="2"/>
  <counter type="BRANCH" missed="0" covered="0"/>
  <counter type="LINE" missed="1" covered="2"/>
  <counter type="METHOD" missed="0" covered="1"/>
  <counter type="CLASS" missed="0" covered="1"/>
</report>
XML

cat >"$CAMPAIGN" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<report name="campaign">
  <package name="pkg">
    <class name="pkg/A" sourcefilename="A.java">
      <counter type="LINE" missed="2" covered="1"/>
    </class>
    <class name="pkg/B" sourcefilename="B.java">
      <counter type="LINE" missed="0" covered="1"/>
    </class>
    <sourcefile name="A.java">
      <line nr="1" mi="1" ci="0" mb="0" cb="0"/>
      <line nr="2" mi="0" ci="1" mb="0" cb="0"/>
      <line nr="3" mi="1" ci="0" mb="0" cb="0"/>
      <counter type="LINE" missed="2" covered="1"/>
    </sourcefile>
    <sourcefile name="B.java">
      <line nr="10" mi="0" ci="1" mb="0" cb="0"/>
      <counter type="LINE" missed="0" covered="1"/>
    </sourcefile>
    <counter type="LINE" missed="2" covered="2"/>
  </package>
  <counter type="INSTRUCTION" missed="2" covered="3"/>
  <counter type="BRANCH" missed="0" covered="0"/>
  <counter type="LINE" missed="2" covered="2"/>
  <counter type="METHOD" missed="0" covered="2"/>
  <counter type="CLASS" missed="0" covered="2"/>
</report>
XML

"$ROOT/scripts/compare-jacoco-coverage.sh" --details-dir "$DETAILS" "$BASELINE" "$CAMPAIGN" >"$OUT"

assert_field() {
  local key="$1"
  local expected="$2"
  grep -qx "$key=$expected" "$OUT" || {
    echo "Expected $key=$expected" >&2
    cat "$OUT" >&2
    exit 1
  }
}

assert_field comparison_status PASS
assert_field line_details_dir "$DETAILS"
assert_field baseline_line_locations_instrumented 3
assert_field baseline_line_locations_covered 2
assert_field baseline_line_locations_missed_only 1
assert_field campaign_line_locations_instrumented 4
assert_field campaign_line_locations_covered 2
assert_field campaign_line_locations_missed_only 2
assert_field line_locations_covered_by_both 1
assert_field line_locations_covered_by_campaign_not_baseline 1
assert_field line_locations_covered_by_baseline_not_campaign 1
assert_field line_locations_covered_union 3
assert_field line_location_coverage_delta 0
assert_field baseline_line_location_coverage_percent 66.6667
assert_field campaign_line_location_coverage_percent 50.0000

for file in \
  baseline-covered-lines.txt \
  campaign-covered-lines.txt \
  covered-by-both-lines.txt \
  campaign-only-covered-lines.txt \
  baseline-only-covered-lines.txt \
  baseline-missed-only-lines.txt \
  campaign-missed-only-lines.txt; do
  [[ -s "$DETAILS/$file" ]] || { echo "missing detail file: $file" >&2; ls -l "$DETAILS" >&2; exit 1; }
done

grep -qx 'pkg/A.java:1' "$DETAILS/baseline-only-covered-lines.txt"
grep -qx 'pkg/A.java:2' "$DETAILS/covered-by-both-lines.txt"
grep -qx 'pkg/B.java:10' "$DETAILS/campaign-only-covered-lines.txt"
grep -qx 'pkg/A.java:3' "$DETAILS/baseline-missed-only-lines.txt"
grep -qx 'pkg/A.java:1' "$DETAILS/campaign-missed-only-lines.txt"
grep -qx 'pkg/A.java:3' "$DETAILS/campaign-missed-only-lines.txt"

echo "PASS: JaCoCo line coverage comparison"
