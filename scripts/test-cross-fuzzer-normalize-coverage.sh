#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$ROOT/.tmp-test-cross-fuzzer-normalize"
rm -rf "$TMP"
mkdir -p "$TMP"

NORMALIZER="$ROOT/scripts/cross-fuzzer-normalize-coverage.py"
[[ -f "$NORMALIZER" ]] || { echo "missing normalizer script" >&2; exit 1; }

echo "=== minimal fixture JaCoCo XML ==="
cat >"$TMP/fixture-a.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<report name="test">
  <sessioninfo id="s1"/>
  <counter type="INSTRUCTION" missed="500" covered="100"/>
  <counter type="BRANCH" missed="50" covered="10"/>
  <counter type="LINE" missed="80" covered="20"/>
  <counter type="METHOD" missed="20" covered="5"/>
  <counter type="CLASS" missed="5" covered="2"/>
  <package name="com/velocitypowered/proxy/test">
    <counter type="INSTRUCTION" missed="200" covered="50"/>
    <counter type="BRANCH" missed="20" covered="5"/>
    <counter type="LINE" missed="30" covered="10"/>
    <counter type="METHOD" missed="8" covered="3"/>
    <counter type="CLASS" missed="2" covered="1"/>
  </package>
</report>
XML

cat >"$TMP/fixture-b.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<report name="test2">
  <sessioninfo id="s2"/>
  <counter type="INSTRUCTION" missed="400" covered="200"/>
  <counter type="BRANCH" missed="40" covered="20"/>
  <counter type="LINE" missed="60" covered="40"/>
  <counter type="METHOD" missed="15" covered="10"/>
  <counter type="CLASS" missed="3" covered="2"/>
  <package name="com/velocitypowered/api/test">
    <counter type="INSTRUCTION" missed="100" covered="100"/>
    <counter type="BRANCH" missed="10" covered="10"/>
    <counter type="LINE" missed="10" covered="20"/>
    <counter type="METHOD" missed="3" covered="5"/>
    <counter type="CLASS" missed="0" covered="1"/>
  </package>
</report>
XML

echo "=== manifest CSV ==="
cat >"$TMP/manifest.csv" <<CSV
label,engine,config,jacoco_xml
fixture-a,aflnet,config1,$TMP/fixture-a.xml
fixture-b,jazzer,config2,$TMP/fixture-b.xml
CSV

echo "=== run normalizer ==="
python3 "$NORMALIZER" \
  --manifest "$TMP/manifest.csv" \
  --output-dir "$TMP/out"

echo "=== assert outputs ==="
ROOT_CSV="$TMP/out/cross-fuzzer-root-coverage.csv"
[[ -f "$ROOT_CSV" ]] || { echo "missing root coverage CSV" >&2; exit 1; }
grep -q 'fixture-a' "$ROOT_CSV" || { echo "root coverage missing fixture-a row" >&2; exit 1; }
grep -q 'fixture-b' "$ROOT_CSV" || { echo "root coverage missing fixture-b row" >&2; exit 1; }

MOD_CSV="$TMP/out/cross-fuzzer-module-coverage.csv"
[[ -f "$MOD_CSV" ]] || { echo "missing module coverage CSV" >&2; exit 1; }
grep -q 'proxy' "$MOD_CSV" || { echo "module coverage missing proxy rows" >&2; exit 1; }
grep -q 'api' "$MOD_CSV" || { echo "module coverage missing api rows" >&2; exit 1; }

# fixture-a proxy module LINE covered must be nonzero
PROXY_LINE_COV="$(python3 -c "
import csv
with open('$MOD_CSV', newline='') as f:
    for row in csv.DictReader(f):
        if row.get('label')=='fixture-a' and row.get('module')=='proxy' and row.get('metric')=='LINE':
            print(row['covered']); break
")"
[[ "${PROXY_LINE_COV:-0}" -gt 0 ]] || { echo "fixture-a proxy LINE coverage is zero" >&2; exit 1; }

# fixture-b api module LINE covered must be nonzero
API_LINE_COV="$(python3 -c "
import csv
with open('$MOD_CSV', newline='') as f:
    for row in csv.DictReader(f):
        if row.get('label')=='fixture-b' and row.get('module')=='api' and row.get('metric')=='LINE':
            print(row['covered']); break
")"
[[ "${API_LINE_COV:-0}" -gt 0 ]] || { echo "fixture-b api LINE coverage is zero" >&2; exit 1; }

OVER_CSV="$TMP/out/cross-fuzzer-engine-package-overlap.csv"
[[ -f "$OVER_CSV" ]] || { echo "missing engine-package overlap CSV" >&2; exit 1; }
grep -q 'aflnet' "$OVER_CSV" || { echo "engine overlap missing aflnet" >&2; exit 1; }
grep -q 'jazzer' "$OVER_CSV" || { echo "engine overlap missing jazzer" >&2; exit 1; }

echo "PASS: cross-fuzzer normalize coverage"
