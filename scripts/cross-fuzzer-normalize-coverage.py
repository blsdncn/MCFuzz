#!/usr/bin/env python3
"""Unified coverage normalization adapter for AFLNet and Jazzer JaCoCo XML outputs.

Reads engine JaCoCo XML paths from a run-manifest CSV, filters to Velocity project
packages (com.velocitypowered.* / org.slf4j / io.netty excluded), merges
package-level aggregates, and emits normalized comparison tables.

Usage:
  python3 scripts/cross-fuzzer-normalize-coverage.py                  \
    --manifest FTL/.../cross-fuzzer-run-manifest.csv                  \
    --output-dir FTL/.../cross-fuzzer-tables                          \
    [--module-rules-file scripts/cross-fuzzer-module-rules.txt]       \
    [--project-prefix com.velocitypowered]
"""

from __future__ import annotations

import argparse
import csv
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_PROJECT_PREFIX = "com.velocitypowered"
DEFAULT_EXCLUDE_PREFIXES = ("org.slf4j", "io.netty")

DEFAULT_MODULE_RULES = [
    ("proxy", "com/velocitypowered/proxy/"),
    ("api", "com/velocitypowered/api/"),
    ("native", "com/velocitypowered/natives/"),
]

ALL_COUNTER_TYPES = ("INSTRUCTION", "BRANCH", "LINE", "METHOD", "CLASS")
COVERAGE_COUNTER_TYPES = ("INSTRUCTION", "BRANCH", "LINE")


@dataclass(frozen=True)
class ModuleRule:
    name: str
    prefix: str


@dataclass
class PackageCoverage:
    name: str
    counters: Dict[str, Tuple[int, int]]  # covered, total per counter type


@dataclass
class RunCoverage:
    label: str
    engine: str
    config: str
    path: Path
    counters: Dict[str, Tuple[int, int]]
    module_counters: Dict[str, Dict[str, Tuple[int, int]]]
    package_counters: Dict[str, PackageCoverage]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Cross-fuzzer JaCoCo coverage normalizer")
    parser.add_argument("--manifest", required=True, type=Path, help="CSV with columns label,engine,config,jacoco_xml")
    parser.add_argument("--output-dir", required=True, type=Path, help="Output directory for normalized tables")
    parser.add_argument("--module-rules-file", type=Path, default=None, help="TSV: module_name,prefix lines (default built-in)")
    parser.add_argument("--project-prefix", default=DEFAULT_PROJECT_PREFIX, help="Package prefix for project packages (default com.velocitypowered)")
    parser.add_argument("--quick-coverage", action="append", default=[], metavar="LABEL:ENGINE:CONFIG:PATH:STRUCTURE_XML",
                        help="Add Jazzer quick-coverage run (label:engine:config:coverage_path:jacoco_structure_xml_path)")
    return parser.parse_args(argv)


def read_manifest(manifest_path: Path) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    with manifest_path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({k: v for k, v in row.items()})
    return rows


def parse_module_rules(path: Path | None) -> List[ModuleRule]:
    if path and path.exists():
        rules: List[ModuleRule] = []
        with path.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 2:
                    rules.append(ModuleRule(parts[0], parts[1]))
        return rules
    return [ModuleRule(name, prefix) for name, prefix in DEFAULT_MODULE_RULES]


def is_project_package(name: str, prefix: str) -> bool:
    name_dot = name.replace("/", ".")
    return name_dot == prefix or name_dot.startswith(prefix + ".")


def is_excluded_package(name: str, exclude_prefixes: Sequence[str]) -> bool:
    name_dot = name.replace("/", ".")
    for p in exclude_prefixes:
        if name_dot == p or name_dot.startswith(p + "."):
            return True
    return False


def parse_counter(element: ET.Element, counter_type: str) -> Tuple[int, int]:
    for c in element.findall("counter"):
        if c.attrib.get("type") == counter_type:
            return int(c.attrib.get("covered", "0")), int(c.attrib.get("missed", "0"))
    return 0, 0


def add_counter(a: Tuple[int, int], b: Tuple[int, int]) -> Tuple[int, int]:
    return (a[0] + b[0], a[1] + b[1])


def load_coverage(rel_path: str, label: str, engine: str, config: str, project_prefix: str) -> RunCoverage:
    path = (ROOT / rel_path).resolve()
    if not path.exists():
        print(f"WARNING: jacoco_xml missing: {rel_path}", file=sys.stderr)
        return RunCoverage(
            label=label, engine=engine, config=config, path=path,
            counters={}, module_counters={}, package_counters={},
        )

    root = ET.parse(path).getroot()

    # root-level counters
    root_counters: Dict[str, Tuple[int, int]] = {}
    for ct in ALL_COUNTER_TYPES:
        root_counters[ct] = parse_counter(root, ct)

    # module counters (using prefix-based aggregation)
    module_rules = parse_module_rules(None)
    module_counters: Dict[str, Dict[str, Tuple[int, int]]] = {
        rule.name: {ct: (0, 0) for ct in ALL_COUNTER_TYPES}
        for rule in module_rules
    }

    # package-level counters for project packages
    package_counters: Dict[str, PackageCoverage] = {}

    for pkg_el in root.findall("package"):
        pkg_name = pkg_el.attrib.get("name", "")
        if not pkg_name:
            continue

        pkg_ct: Dict[str, Tuple[int, int]] = {}
        for ct in ALL_COUNTER_TYPES:
            pkg_ct[ct] = parse_counter(pkg_el, ct)

        # assign to module rules
        for rule in module_rules:
            if (pkg_name + "/").startswith(rule.prefix):
                for ct in ALL_COUNTER_TYPES:
                    module_counters[rule.name][ct] = add_counter(
                        module_counters[rule.name][ct], pkg_ct[ct]
                    )

        # include in package table if it matches project prefix and isn't excluded
        if is_project_package(pkg_name, project_prefix) and not is_excluded_package(pkg_name, DEFAULT_EXCLUDE_PREFIXES):
            package_counters[pkg_name] = PackageCoverage(
                name=pkg_name,
                counters=pkg_ct,
            )

    return RunCoverage(
        label=label, engine=engine, config=config, path=path,
        counters=root_counters, module_counters=module_counters,
        package_counters=package_counters,
    )


def pct(covered: int, total: int) -> float:
    return round(100.0 * covered / total, 1) if total else 0.0


def write_csv(path: Path, rows: List[Dict[str, object]], fieldnames: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_md_table(path: Path, fieldnames: Sequence[str], rows: List[List[object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: List[str] = []
    lines.append("| " + " | ".join(fieldnames) + " |")
    lines.append("| " + " | ".join(["---"] * len(fieldnames)) + " |")
    for row in rows:
        lines.append("| " + " | ".join(str(v) for v in row) + " |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def emit_root_summary(runs: List[RunCoverage], out_dir: Path) -> None:
    rows: List[Dict[str, object]] = []
    for run in runs:
        for ct in ALL_COUNTER_TYPES:
            c, m = run.counters.get(ct, (0, 0))
            total = c + m
            rows.append({
                "label": run.label,
                "engine": run.engine,
                "config": run.config,
                "metric": ct,
                "covered": c,
                "total": total,
                "pct": pct(c, total),
            })

    fields = ["label", "engine", "config", "metric", "covered", "total", "pct"]
    write_csv(out_dir / "cross-fuzzer-root-coverage.csv", rows, fields)
    write_md_table(out_dir / "cross-fuzzer-root-coverage.md", fields, [[r[k] for k in fields] for r in rows])


def emit_module_summary(runs: List[RunCoverage], out_dir: Path) -> None:
    rows: List[Dict[str, object]] = []
    for run in runs:
        for mod_name in sorted(run.module_counters.keys()):
            for ct in COVERAGE_COUNTER_TYPES:
                c, m = run.module_counters[mod_name].get(ct, (0, 0))
                total = c + m
                rows.append({
                    "label": run.label,
                    "engine": run.engine,
                    "config": run.config,
                    "module": mod_name,
                    "metric": ct,
                    "covered": c,
                    "total": total,
                    "pct": pct(c, total),
                })

    fields = ["label", "engine", "config", "module", "metric", "covered", "total", "pct"]
    write_csv(out_dir / "cross-fuzzer-module-coverage.csv", rows, fields)
    write_md_table(out_dir / "cross-fuzzer-module-coverage.md", fields, [[r[k] for k in fields] for r in rows])


def emit_package_coverage(runs: List[RunCoverage], out_dir: Path) -> None:
    rows: List[Dict[str, object]] = []
    for run in runs:
        for pkg_name in sorted(run.package_counters):
            pkg = run.package_counters[pkg_name]
            for ct in COVERAGE_COUNTER_TYPES:
                c, m = pkg.counters.get(ct, (0, 0))
                total = c + m
                rows.append({
                    "label": run.label,
                    "engine": run.engine,
                    "config": run.config,
                    "package": pkg_name,
                    "metric": ct,
                    "covered": c,
                    "total": total,
                    "pct": pct(c, total),
                })

    fields = ["label", "engine", "config", "package", "metric", "covered", "total", "pct"]
    write_csv(out_dir / "cross-fuzzer-package-coverage.csv", rows, fields)
    write_md_table(out_dir / "cross-fuzzer-package-coverage.md", fields, [[r[k] for k in fields] for r in rows[:200]])


def load_quick_coverage(quick_path: str, label: str, engine: str, config: str, jacoco_structure_xml: str) -> RunCoverage:
    """Load Jazzer quick coverage (source-file text report) and map to packages
    using the JaCoCo XML structure as a sourcefile→package lookup."""
    import re
    path = (ROOT / quick_path).resolve()
    jx_path = (ROOT / jacoco_structure_xml).resolve()
    if not path.exists():
        print(f"WARNING: quick coverage file missing: {quick_path}", file=sys.stderr)
        return RunCoverage(label=label, engine=engine, config=config, path=path,
                          counters={}, module_counters={}, package_counters={})

    # Build sourcefile → package lookup from structure JaCoCo XML
    sf_to_pkg: Dict[str, str] = {}
    if jx_path.exists():
        try:
            tree = ET.parse(jx_path)
            for pkg_el in tree.getroot().findall("package"):
                pkg_name = pkg_el.attrib.get("name", "")
                for sf_el in pkg_el.findall("sourcefile"):
                    sf_name = sf_el.attrib.get("name", "")
                    if sf_name:
                        sf_to_pkg[sf_name] = pkg_name
        except Exception as exc:
            print(f"WARNING: failed to parse structure XML: {exc}", file=sys.stderr)

    # Parse Jazzer quick coverage
    current_section: str | None = None
    line_rows: List[Tuple[str, int, int]] = []  # (sourcefile, covered, total)
    branch_rows: List[Tuple[str, int, int]] = []
    for line in path.read_text(errors="replace").splitlines():
        if line == "Line coverage:":
            current_section = "line"
            continue
        if line == "Branch coverage:":
            current_section = "branch"
            continue
        if line.endswith("coverage:"):
            current_section = None
            continue
        if current_section == "line":
            m = re.match(r"([^:]+\\.java):\\s+(\\d+)/(\\d+)\\s+\\(([^)]*)\\)", line)
            if m:
                name, c, t, _ = m.groups()
                line_rows.append((name, int(c), int(t)))
        elif current_section == "branch":
            m = re.match(r"([^:]+\\.java):\\s+(\\d+)/(\\d+)\\s+\\(([^)]*)\\)", line)
            if m:
                name, c, t, _ = m.groups()
                branch_rows.append((name, int(c), int(t)))

    # Aggregate by package
    pkg_line: Dict[str, Tuple[int, int]] = defaultdict(lambda: (0, 0))
    pkg_branch: Dict[str, Tuple[int, int]] = defaultdict(lambda: (0, 0))
    for sf_name, c, t in line_rows:
        pkg = sf_to_pkg.get(sf_name)
        if pkg is None:
            continue
        pkg_line[pkg] = (pkg_line[pkg][0] + c, pkg_line[pkg][1] + t)
    for sf_name, c, t in branch_rows:
        pkg = sf_to_pkg.get(sf_name)
        if pkg is None:
            continue
        pkg_branch[pkg] = (pkg_branch[pkg][0] + c, pkg_branch[pkg][1] + t)

    # Build package counters dict
    package_counters: Dict[str, PackageCoverage] = {}
    all_pkgs = set(pkg_line) | set(pkg_branch)
    for pkg in all_pkgs:
        lc, lt = pkg_line.get(pkg, (0, 0))
        bc, bt = pkg_branch.get(pkg, (0, 0))
        package_counters[pkg] = PackageCoverage(
            name=pkg,
            counters={"LINE": (lc, lt), "BRANCH": (bc, bt),
                     "INSTRUCTION": (lc, lt), "METHOD": (0, 0), "CLASS": (0, 0)},
        )

    # Module counters
    module_rules = parse_module_rules(None)
    module_counters: Dict[str, Dict[str, Tuple[int, int]]] = {
        rule.name: {ct: (0, 0) for ct in ALL_COUNTER_TYPES}
        for rule in module_rules
    }
    for pkg_name, pkg in package_counters.items():
        for rule in module_rules:
            if (pkg_name + "/").startswith(rule.prefix):
                for ct in ("LINE", "BRANCH"):
                    module_counters[rule.name][ct] = add_counter(
                        module_counters[rule.name][ct], pkg.counters[ct]
                    )
    # Root counters: sum all module counters
    root_counters: Dict[str, Tuple[int, int]] = {ct: (0, 0) for ct in ALL_COUNTER_TYPES}
    for mod in module_counters.values():
        for ct in ("LINE", "BRANCH"):
            root_counters[ct] = add_counter(root_counters[ct], mod[ct])
    return RunCoverage(
        label=label, engine=engine, config=config, path=path,
        counters=root_counters, module_counters=module_counters,
        package_counters=package_counters,
    )


def emit_package_overlap(runs: List[RunCoverage], out_dir: Path) -> None:
    """Per-engine package overlap where LINE > 0 for any config."""
    # group by engine
    engine_packages: Dict[str, Dict[str, set]] = defaultdict(lambda: defaultdict(set))
    for run in runs:
        for pkg_name, pkg in run.package_counters.items():
            c, _ = pkg.counters.get("LINE", (0, 0))
            if c > 0:
                engine_packages[run.engine][run.config].add(pkg_name)

    # pairwise overlap within each engine
    rows: List[Dict[str, object]] = []
    for engine in sorted(engine_packages):
        configs = sorted(engine_packages[engine].keys())
        for i, c1 in enumerate(configs):
            for c2 in configs[i:]:
                s1 = engine_packages[engine][c1]
                s2 = engine_packages[engine][c2]
                both = len(s1 & s2)
                only_left = len(s1 - s2)
                only_right = len(s2 - s1)
                rows.append({
                    "engine": engine, "config_a": c1, "config_b": c2,
                    "config_a_pkgs": len(s1), "config_b_pkgs": len(s2),
                    "both_nonzero": both, "only_config_a": only_left, "only_config_b": only_right,
                })

    fields = ["engine", "config_a", "config_b", "config_a_pkgs", "config_b_pkgs", "both_nonzero", "only_config_a", "only_config_b"]
    write_csv(out_dir / "cross-fuzzer-package-overlap.csv", rows, fields)
    write_md_table(out_dir / "cross-fuzzer-package-overlap.md", fields, [[r[k] for k in fields] for r in rows])

    # cross-engine overlap across all configs
    cross_rows: List[Dict[str, object]] = []
    engines = sorted(engine_packages)
    for i in range(len(engines)):
        for j in range(i + 1, len(engines)):
            e1, e2 = engines[i], engines[j]
            all_e1: set = set().union(*engine_packages[e1].values()) if engine_packages[e1] else set()
            all_e2: set = set().union(*engine_packages[e2].values()) if engine_packages[e2] else set()
            cross_rows.append({
                "engine_a": e1, "engine_b": e2,
                "engine_a_pkgs": len(all_e1), "engine_b_pkgs": len(all_e2),
                "both_nonzero": len(all_e1 & all_e2),
                "only_engine_a": len(all_e1 - all_e2),
                "only_engine_b": len(all_e2 - all_e1),
            })

    cfields = ["engine_a", "engine_b", "engine_a_pkgs", "engine_b_pkgs", "both_nonzero", "only_engine_a", "only_engine_b"]
    write_csv(out_dir / "cross-fuzzer-engine-package-overlap.csv", cross_rows, cfields)
    write_md_table(out_dir / "cross-fuzzer-engine-package-overlap.md", cfields, [[r[k] for k in cfields] for r in cross_rows])


def main(argv: Sequence[str] | None = None) -> None:
    args = parse_args(argv)
    out_dir = args.output_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest_rows = read_manifest(args.manifest)
    project_prefix = args.project_prefix

    runs: List[RunCoverage] = []
    for row in manifest_rows:
        label = row.get("label", "unknown")
        engine = row.get("engine", "unknown")
        config = row.get("config", "unknown")
        jacoco_xml = row.get("jacoco_xml", "")
        if not jacoco_xml:
            print(f"WARNING: no jacoco_xml for {label}", file=sys.stderr)
            continue
        runs.append(load_coverage(jacoco_xml, label, engine, config, project_prefix))

    for qc in args.quick_coverage:
        parts = qc.split(":", 4)
        if len(parts) != 5:
            print(f"WARNING: invalid quick-coverage spec (expected label:engine:config:coverage_path:structure_xml): {qc}", file=sys.stderr)
            continue
        label, engine, config, qc_path, struct_xml = parts
        runs.append(load_quick_coverage(qc_path, label, engine, config, struct_xml))

    print(f"loaded={len(runs)} missing={sum(1 for r in runs if not r.counters)}", file=sys.stderr)

    emit_root_summary(runs, out_dir)
    emit_module_summary(runs, out_dir)
    emit_package_coverage(runs, out_dir)
    emit_package_overlap(runs, out_dir)

    print(f"output_dir={out_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
