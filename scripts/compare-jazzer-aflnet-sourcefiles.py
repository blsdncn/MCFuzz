#!/usr/bin/env python3
"""Parse Jazzer quick-coverage and AFLNet JaCoCo XML for sourcefile-level comparison."""
from __future__ import annotations
import csv
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent

class SourceCov(NamedTuple):
    source: str
    metric: str  # LINE or BRANCH
    covered: int
    total: int

def parse_jazzer_quick(path: Path) -> list[SourceCov]:
    """Parse Jazzer quick-coverage format: 'File.java: X/Y (pct%)'"""
    rows = []
    section = "LINE"  # default; file starts with 'Branch coverage:' header
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("Branch coverage:"):
                section = "BRANCH"
                continue
            if line.startswith("Line coverage:"):
                section = "LINE"
                continue
            m = re.match(r'^([^:]+\.java):\s+(\d+)/(\d+)\s+\(', line)
            if m:
                fname = m.group(1)
                covered = int(m.group(2))
                total = int(m.group(3))
                rows.append(SourceCov(fname, section, covered, total))
    return rows

def parse_jacoco_xml(xml_path: Path) -> list[SourceCov]:
    """Parse JaCoCo XML for sourcefile-level LINE and BRANCH coverage."""
    rows = []
    tree = ET.parse(xml_path)
    root = tree.getroot()
    for pkg in root.findall("package"):
        pkg_name = pkg.attrib.get("name", "").replace("/", ".")
        for sf in pkg.findall("sourcefile"):
            sf_name = sf.attrib.get("name", "")
            for counter in sf.findall("counter"):
                ctype = counter.attrib.get("type", "")
                if ctype in ("LINE", "BRANCH"):
                    covered = int(counter.attrib.get("covered", "0"))
                    missed = int(counter.attrib.get("missed", "0"))
                    total = covered + missed
                    rows.append(SourceCov(sf_name, ctype, covered, total))
    return rows

def parse_run_summary(path: Path) -> dict[str, str]:
    data = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    return data

def is_velocity_source(fname: str) -> bool:
    """Check if sourcefile belongs to Velocity project (not a dependency)."""
    # Jazzer quick-coverage uses bare filenames; JaCoCo uses sourcefile names.
    # We match on Velocity-specific class names.
    velocity_patterns = [
        "Packet", "Session", "Protocol", "State", "Registry",
        "Connection", "Velocity", "Handshake", "Login", "Status",
        "Server", "Config", "Player", "Chat", "Brand", "Plugin",
        "Command", "Tab", "Boss", "Resource", "Settings", "Fuzz",
        "Compression", "Cipher", "Encryption",
    ]
    return any(p in fname for p in velocity_patterns)

def main():
    import sys
    
    # Jazzer coverage files
    jazzer_stateful = ROOT / "velocity-jazzer-integration" / "artifacts" / "jazzer-coverage"
    jazzer_stateless = ROOT / "velocity-jazzer-integration" / "artifacts" / "jazzer-coverage (1)"
    
    # AFLNet JaCoCo XMLs
    aflnet_24h_xml = ROOT / "eval-runs" / "20260505T045009Z-state-aware-86400s" / "campaign" / "coverage" / "jacoco.xml"
    aflnet_11h_xml = ROOT / "eval-runs" / "20260507T071141Z-state-aware-39600s" / "campaign" / "coverage" / "jacoco.xml"
    baseline_xml = ROOT / "eval-runs" / "20260503T042725Z-state-aware-600s" / "velocity-jacoco-baseline" / "jacoco.xml"
    
    out_dir = ROOT / "FTL" / "investigations" / "evaluation-artifact-deep-dive" / "jazzer-comparison" / "sourcefile-comparison"
    out_dir.mkdir(parents=True, exist_ok=True)
    
    # Parse Jazzer
    jazzer_sf = parse_jazzer_quick(jazzer_stateful)
    jazzer_sl = parse_jazzer_quick(jazzer_stateless)
    
    # Parse AFLNet
    aflnet_24h = parse_jacoco_xml(aflnet_24h_xml) if aflnet_24h_xml.exists() else []
    aflnet_11h = parse_jacoco_xml(aflnet_11h_xml) if aflnet_11h_xml.exists() else []
    baseline = parse_jacoco_xml(baseline_xml) if baseline_xml.exists() else []
    
    # Build lookup: sourcefile -> {metric: (covered, total)}
    def build_lookup(rows: list[SourceCov]) -> dict[str, dict[str, tuple[int, int]]]:
        lookup: dict[str, dict[str, tuple[int, int]]] = {}
        for r in rows:
            if r.source not in lookup:
                lookup[r.source] = {}
            lookup[r.source][r.metric] = (r.covered, r.total)
        return lookup
    
    jazzer_sf_lu = build_lookup(jazzer_sf)
    jazzer_sl_lu = build_lookup(jazzer_sl)
    aflnet_24h_lu = build_lookup(aflnet_24h)
    aflnet_11h_lu = build_lookup(aflnet_11h)
    baseline_lu = build_lookup(baseline)
    
    # Get Velocity sourcefiles from each
    def velocity_sources(lookup: dict[str, dict[str, tuple[int, int]]]) -> set[str]:
        return {s for s in lookup if is_velocity_source(s)}
    
    jazzer_sf_vel = velocity_sources(jazzer_sf_lu)
    jazzer_sl_vel = velocity_sources(jazzer_sl_lu)
    aflnet_24h_vel = velocity_sources(aflnet_24h_lu)
    aflnet_11h_vel = velocity_sources(aflnet_11h_lu)
    baseline_vel = velocity_sources(baseline_lu)
    
    # Combined Jazzer sources
    jazzer_all_vel = jazzer_sf_vel | jazzer_sl_vel
    
    # Intersection analysis
    both = jazzer_all_vel & aflnet_24h_vel
    only_jazzer = jazzer_all_vel - aflnet_24h_vel
    only_aflnet = aflnet_24h_vel - jazzer_all_vel
    
    # Write sourcefile overlap table
    fields = ["sourcefile", "metric", "jazzer_stateful_cov", "jazzer_stateful_total",
              "jazzer_stateless_cov", "jazzer_stateless_total",
              "aflnet_24h_cov", "aflnet_24h_total", "aflnet_11h_cov", "aflnet_11h_total",
              "baseline_cov", "baseline_total"]
    
    overlap_rows = []
    all_sources = sorted(jazzer_all_vel | aflnet_24h_vel | aflnet_11h_vel | baseline_vel)
    for src in all_sources:
        for metric in ("LINE", "BRANCH"):
            jf = jazzer_sf_lu.get(src, {}).get(metric, (0, 0))
            jl = jazzer_sl_lu.get(src, {}).get(metric, (0, 0))
            a24 = aflnet_24h_lu.get(src, {}).get(metric, (0, 0))
            a11 = aflnet_11h_lu.get(src, {}).get(metric, (0, 0))
            bl = baseline_lu.get(src, {}).get(metric, (0, 0))
            if jf[1] > 0 or jl[1] > 0 or a24[1] > 0 or a11[1] > 0 or bl[1] > 0:
                overlap_rows.append({
                    "sourcefile": src,
                    "metric": metric,
                    "jazzer_stateful_cov": jf[0], "jazzer_stateful_total": jf[1],
                    "jazzer_stateless_cov": jl[0], "jazzer_stateless_total": jl[1],
                    "aflnet_24h_cov": a24[0], "aflnet_24h_total": a24[1],
                    "aflnet_11h_cov": a11[0], "aflnet_11h_total": a11[1],
                    "baseline_cov": bl[0], "baseline_total": bl[1],
                })
    
    csv_path = out_dir / "sourcefile-coverage-overlap.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(overlap_rows)
    
    # Summary stats
    summary_lines = []
    summary_lines.append("# Sourcefile-Level Coverage Comparison")
    summary_lines.append("")
    summary_lines.append("## Source counts (Velocity project classes)")
    summary_lines.append("")
    summary_lines.append(f"| Source | LINE sourcefiles | BRANCH sourcefiles |")
    summary_lines.append(f"|---|---|---|")
    for label, lu in [("Jazzer 6h stateful", jazzer_sf_lu), ("Jazzer stateless", jazzer_sl_lu),
                       ("AFLNet 24h", aflnet_24h_lu), ("AFLNet 11h epoch", aflnet_11h_lu),
                       ("Baseline", baseline_lu)]:
        vel = velocity_sources(lu)
        line_sf = sum(1 for s in vel if lu.get(s, {}).get("LINE", (0,0))[1] > 0)
        branch_sf = sum(1 for s in vel if lu.get(s, {}).get("BRANCH", (0,0))[1] > 0)
        summary_lines.append(f"| {label} | {line_sf} | {branch_sf} |")
    
    summary_lines.append("")
    summary_lines.append("## Overlap (LINE coverage, sourcefile-level)")
    summary_lines.append("")
    summary_lines.append(f"| Comparison | Both | Only A | Only B |")
    summary_lines.append(f"|---|---|---|---|")
    summary_lines.append(f"| Jazzer (all) vs AFLNet 24h | {len(both)} | {len(only_jazzer)} | {len(only_aflnet)} |")
    
    # Jazzer-only sourcefiles with nonzero coverage
    jazzer_only_nonzero = sorted([s for s in only_jazzer 
                                   if jazzer_sf_lu.get(s, {}).get("LINE", (0,0))[0] > 0
                                   or jazzer_sl_lu.get(s, {}).get("LINE", (0,0))[0] > 0])
    summary_lines.append("")
    summary_lines.append("## Jazzer-only sourcefiles with nonzero LINE coverage")
    summary_lines.append("")
    for src in jazzer_only_nonzero[:30]:
        jf = jazzer_sf_lu.get(src, {}).get("LINE", (0, 0))
        jl = jazzer_sl_lu.get(src, {}).get("LINE", (0, 0))
        pct = f"{100*jf[0]/jf[1]:.1f}%" if jf[1] > 0 else "0%"
        summary_lines.append(f"- `{src}`: stateful {jf[0]}/{jf[1]} ({pct}), stateless {jl[0]}/{jl[1]}")
    
    # AFLNet-only sourcefiles with nonzero coverage
    aflnet_only_nonzero = sorted([s for s in only_aflnet
                                   if aflnet_24h_lu.get(s, {}).get("LINE", (0,0))[0] > 0])
    summary_lines.append("")
    summary_lines.append("## AFLNet-only sourcefiles with nonzero LINE coverage")
    summary_lines.append("")
    for src in aflnet_only_nonzero[:30]:
        a = aflnet_24h_lu.get(src, {}).get("LINE", (0, 0))
        bl = baseline_lu.get(src, {}).get("LINE", (0, 0))
        pct = f"{100*a[0]/a[1]:.1f}%" if a[1] > 0 else "0%"
        summary_lines.append(f"- `{src}`: 24h {a[0]}/{a[1]} ({pct}), baseline {bl[0]}/{bl[1]}")
    
    # Both sources — top by combined coverage
    both_rows = []
    for src in both:
        jf = jazzer_sf_lu.get(src, {}).get("LINE", (0, 0))
        a24 = aflnet_24h_lu.get(src, {}).get("LINE", (0, 0))
        if jf[1] > 0 and a24[1] > 0:
            both_rows.append((src, jf[0], jf[1], a24[0], a24[1]))
    both_rows.sort(key=lambda r: r[1] + r[3], reverse=True)
    
    summary_lines.append("")
    summary_lines.append("## Both Jazzer + AFLNet — top sourcefiles by combined LINE coverage")
    summary_lines.append("")
    summary_lines.append("| Sourcefile | Jazzer cov | Jazzer total | AFLNet 24h cov | AFLNet 24h total |")
    summary_lines.append("|---|---|---|---|---|")
    for src, jc, jt, ac, at in both_rows[:30]:
        summary_lines.append(f"| `{src}` | {jc} | {jt} | {ac} | {at} |")
    
    # Write summary
    summary_path = out_dir / "sourcefile-comparison-summary.md"
    summary_path.write_text("\n".join(summary_lines) + "\n")
    
    print(f"sourcefile_overlap_rows={len(overlap_rows)}")
    print(f"velocity_sources_jazzer_stateful={len(jazzer_sf_vel)}")
    print(f"velocity_sources_jazzer_stateless={len(jazzer_sl_vel)}")
    print(f"velocity_sources_aflnet_24h={len(aflnet_24h_vel)}")
    print(f"velocity_sources_aflnet_11h={len(aflnet_11h_vel)}")
    print(f"velocity_sources_baseline={len(baseline_vel)}")
    print(f"both_jazzer_aflnet={len(both)}")
    print(f"only_jazzer={len(only_jazzer)}")
    print(f"only_aflnet={len(only_aflnet)}")
    print(f"jazzer_only_nonzero={len(jazzer_only_nonzero)}")
    print(f"aflnet_only_nonzero={len(aflnet_only_nonzero)}")
    print(f"csv={csv_path}")
    print(f"summary={summary_path}")

if __name__ == "__main__":
    main()
