#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BASELINE="$TMPDIR/baseline.xml"
CAMPAIGN="$TMPDIR/campaign.xml"
OUT="$TMPDIR/comparison.out"

cat >"$BASELINE" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<report name="baseline">
  <package name="com/velocitypowered/proxy/protocol">
    <class name="com/velocitypowered/proxy/protocol/PacketRegistry" sourcefilename="PacketRegistry.java">
      <counter type="LINE" missed="0" covered="5"/>
      <counter type="INSTRUCTION" missed="0" covered="10"/>
    </class>
    <class name="com/velocitypowered/proxy/protocol/ProtocolUtils" sourcefilename="ProtocolUtils.java">
      <counter type="LINE" missed="8" covered="0"/>
      <counter type="INSTRUCTION" missed="12" covered="0"/>
    </class>
  </package>
  <package name="com/velocitypowered/api/proxy">
    <class name="com/velocitypowered/api/proxy/Player" sourcefilename="Player.java">
      <counter type="LINE" missed="0" covered="3"/>
      <counter type="INSTRUCTION" missed="0" covered="7"/>
    </class>
  </package>
  <counter type="INSTRUCTION" missed="90" covered="10"/>
  <counter type="BRANCH" missed="18" covered="2"/>
  <counter type="LINE" missed="45" covered="5"/>
  <counter type="METHOD" missed="9" covered="1"/>
  <counter type="CLASS" missed="4" covered="1"/>
</report>
XML

cat >"$CAMPAIGN" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<report name="campaign">
  <package name="com/velocitypowered/proxy/protocol">
    <class name="com/velocitypowered/proxy/protocol/PacketRegistry" sourcefilename="PacketRegistry.java">
      <counter type="LINE" missed="0" covered="6"/>
      <counter type="INSTRUCTION" missed="0" covered="11"/>
    </class>
    <class name="com/velocitypowered/proxy/protocol/ProtocolUtils" sourcefilename="ProtocolUtils.java">
      <counter type="LINE" missed="0" covered="4"/>
      <counter type="INSTRUCTION" missed="0" covered="9"/>
    </class>
  </package>
  <package name="com/velocitypowered/proxy/connection">
    <class name="com/velocitypowered/proxy/connection/MinecraftConnection" sourcefilename="MinecraftConnection.java">
      <counter type="LINE" missed="0" covered="7"/>
      <counter type="INSTRUCTION" missed="0" covered="12"/>
    </class>
  </package>
  <counter type="INSTRUCTION" missed="80" covered="20"/>
  <counter type="BRANCH" missed="17" covered="3"/>
  <counter type="LINE" missed="42" covered="8"/>
  <counter type="METHOD" missed="8" covered="2"/>
  <counter type="CLASS" missed="3" covered="2"/>
</report>
XML

"$ROOT/scripts/compare-jacoco-coverage.sh" "$BASELINE" "$CAMPAIGN" >"$OUT"

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
assert_field comparison_tool jacoco
assert_field comparison_scope coarse-counters-class-package-and-line-location-deltas
assert_field line_details_dir not-requested
assert_field comparison_thresholds none
assert_field baseline_instruction_covered 10
assert_field campaign_instruction_covered 20
assert_field instruction_covered_delta 10
assert_field baseline_line_covered 5
assert_field campaign_line_covered 8
assert_field line_covered_delta 3
assert_field baseline_branch_covered 2
assert_field campaign_branch_covered 3
assert_field branch_covered_delta 1
assert_field baseline_method_covered 1
assert_field campaign_method_covered 2
assert_field method_covered_delta 1
assert_field baseline_class_covered 1
assert_field campaign_class_covered 2
assert_field class_covered_delta 1
assert_field baseline_classes_with_covered_lines 2
assert_field campaign_classes_with_covered_lines 3
assert_field classes_covered_by_both 1
assert_field classes_covered_by_campaign_not_baseline 2
assert_field classes_covered_by_baseline_not_campaign 1
assert_field baseline_packages_with_covered_lines 2
assert_field campaign_packages_with_covered_lines 2
assert_field packages_covered_by_both 1
assert_field packages_covered_by_campaign_not_baseline 1
assert_field packages_covered_by_baseline_not_campaign 1
assert_field baseline_line_locations_instrumented 0
assert_field campaign_line_locations_instrumented 0
assert_field line_locations_covered_by_campaign_not_baseline 0
assert_field line_locations_covered_by_baseline_not_campaign 0

if grep -Eq 'threshold|improvement_status|better_than_baseline' "$OUT" && ! grep -qx 'comparison_thresholds=none' "$OUT"; then
  echo "Comparison emitted premature threshold/improvement claim" >&2
  cat "$OUT" >&2
  exit 1
fi

echo "PASS: JaCoCo coverage comparison"
