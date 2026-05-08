#!/usr/bin/env python3
from __future__ import annotations

import csv
import math
import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "FTL" / "investigations" / "evaluation-artifact-deep-dive" / "jazzer-comparison" / "report-artifacts"

JAZZER_STATEFUL = ROOT / "velocity-jazzer-integration" / "artifacts" / "jazzer-coverage"
JAZZER_STATELESS = ROOT / "velocity-jazzer-integration" / "artifacts" / "jazzer-coverage (1)"
JAZZER_STATEFUL_LOG = ROOT / "velocity-jazzer-integration" / "artifacts" / "jazzer-stderr.log"
JAZZER_STATELESS_LOG = ROOT / "velocity-jazzer-integration" / "artifacts" / "jazzer-stderr (1).log"

AFLNET_24H_XML = ROOT / "eval-runs" / "20260505T045009Z-state-aware-86400s" / "campaign" / "coverage" / "jacoco.xml"
AFLNET_11H_XML = ROOT / "eval-runs" / "20260507T071141Z-state-aware-39600s" / "campaign" / "coverage" / "jacoco.xml"
BASELINE_XML = ROOT / "eval-runs" / "20260503T042725Z-state-aware-600s" / "velocity-jacoco-baseline" / "jacoco.xml"

AFLNET_24H_SUMMARY = ROOT / "eval-runs" / "20260505T045009Z-state-aware-86400s" / "campaign" / "run-summary.txt"
AFLNET_11H_SUMMARY = ROOT / "eval-runs" / "20260507T071141Z-state-aware-39600s" / "campaign" / "run-summary.txt"
AFLNET_24H_STATS = ROOT / "eval-runs" / "20260505T045009Z-state-aware-86400s" / "campaign" / "aflnet-out" / "fuzzer_stats"
AFLNET_11H_STATS = ROOT / "eval-runs" / "20260507T071141Z-state-aware-39600s" / "campaign" / "aflnet-out" / "fuzzer_stats"

@dataclass(frozen=True)
class Counter:
    covered: int
    total: int

    @property
    def pct(self) -> float | None:
        if self.total <= 0:
            return None
        return self.covered / self.total


def safe_pct(c: Counter | None) -> str:
    if c is None or c.total <= 0:
        return "NA"
    return f"{100*c.covered/c.total:.1f}%"


def read_kv(path: Path, sep: str = "=") -> dict[str, str]:
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if sep in line:
            k, v = line.split(sep, 1)
            out[k.strip()] = v.strip()
    return out


def read_fuzzer_stats(path: Path) -> dict[str, str]:
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def parse_jazzer_quick(path: Path) -> dict[str, dict[str, Counter]]:
    data: dict[str, dict[str, Counter]] = defaultdict(dict)
    metric = None
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if line == "Branch coverage:":
            metric = "BRANCH"
            continue
        if line == "Line coverage:":
            metric = "LINE"
            continue
        if metric is None:
            continue
        m = re.match(r"^([^:]+\.java):\s+(\d+)/(\d+)\s+\(", line)
        if not m:
            continue
        data[m.group(1)][metric] = Counter(int(m.group(2)), int(m.group(3)))
    return dict(data)


def parse_jacoco_xml(path: Path) -> dict[str, dict[str, Counter]]:
    data: dict[str, dict[str, Counter]] = defaultdict(dict)
    root = ET.parse(path).getroot()
    for package in root.findall("package"):
        pkg = package.attrib.get("name", "").replace("/", ".")
        if not pkg.startswith("com.velocitypowered"):
            continue
        for sf in package.findall("sourcefile"):
            name = sf.attrib.get("name", "")
            for ctr in sf.findall("counter"):
                typ = ctr.attrib.get("type")
                if typ not in {"LINE", "BRANCH"}:
                    continue
                covered = int(ctr.attrib.get("covered", "0"))
                missed = int(ctr.attrib.get("missed", "0"))
                # JaCoCo sourcefile names are unique enough for this repo in practice;
                # if duplicated, aggregate by filename because Jazzer quick coverage is filename-only.
                old = data[name].get(typ, Counter(0, 0))
                data[name][typ] = Counter(old.covered + covered, old.total + covered + missed)
    return dict(data)


def source_index() -> dict[str, list[str]]:
    roots = [
        ROOT / "velocity" / "proxy" / "src" / "main" / "java",
        ROOT / "velocity" / "api" / "src" / "main" / "java",
        ROOT / "velocity" / "native" / "src" / "main" / "java",
        ROOT / "velocity-jazzer-integration" / "proxy" / "src" / "test" / "java",
    ]
    idx: dict[str, list[str]] = defaultdict(list)
    for base in roots:
        if not base.exists():
            continue
        for p in base.rglob("*.java"):
            idx[p.name].append(str(p.relative_to(ROOT)))
    return dict(idx)


def category_for(source: str, paths: list[str]) -> str:
    text = " ".join(paths + [source]).lower()
    if "fuzztarget" in source.lower() or "/fuzz/" in text:
        return "jazzer-fuzz-target"
    if "packet" in source.lower() or "/protocol/packet/" in text or "protocolutils" in source.lower() or "stateregistry" in source.lower():
        return "packet-protocol-codec"
    if "connection" in text or "session" in text or "handshake" in text or "login" in text or "connectedplayer" in source.lower():
        return "connection-session-login"
    if "config" in text or "configuration" in source.lower() or "plugin" in text or "logger" in source.lower() or "command" in text:
        return "config-plugin-command"
    if "server" in text or "backend" in text or "routing" in text:
        return "server-backend-routing"
    if "/api/" in text:
        return "api"
    if "/native/" in text or "cipher" in source.lower() or "compress" in source.lower():
        return "native"
    return "utility-other"


def max_counter(a: Counter | None, b: Counter | None) -> Counter:
    if a is None:
        return b or Counter(0, 0)
    if b is None:
        return a
    total = max(a.total, b.total)
    covered = max(a.covered, b.covered)
    return Counter(covered, total)


def write_csv(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})


def write_md_table(path: Path, headers: list[str], rows: list[list[object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        f.write("| " + " | ".join(headers) + " |\n")
        f.write("| " + " | ".join(["---"] * len(headers)) + " |\n")
        for r in rows:
            f.write("| " + " | ".join(str(x) for x in r) + " |\n")


def make_venn_svg(path: Path, title: str, left_label: str, right_label: str, only_left: int, both: int, only_right: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    svg = f"""<svg xmlns='http://www.w3.org/2000/svg' width='900' height='520' viewBox='0 0 900 520'>
  <style>text{{font-family:Arial,sans-serif}} .title{{font-size:28px;font-weight:bold}} .label{{font-size:20px;font-weight:bold}} .num{{font-size:34px;font-weight:bold}} .small{{font-size:16px}}</style>
  <rect width='900' height='520' fill='white'/>
  <text x='450' y='45' text-anchor='middle' class='title'>{title}</text>
  <circle cx='345' cy='265' r='170' fill='#1f77b4' fill-opacity='0.34' stroke='#1f77b4' stroke-width='4'/>
  <circle cx='555' cy='265' r='170' fill='#ff7f0e' fill-opacity='0.34' stroke='#ff7f0e' stroke-width='4'/>
  <text x='255' y='110' text-anchor='middle' class='label'>{left_label}</text>
  <text x='645' y='110' text-anchor='middle' class='label'>{right_label}</text>
  <text x='270' y='275' text-anchor='middle' class='num'>{only_left}</text>
  <text x='450' y='275' text-anchor='middle' class='num'>{both}</text>
  <text x='630' y='275' text-anchor='middle' class='num'>{only_right}</text>
  <text x='270' y='310' text-anchor='middle' class='small'>only</text>
  <text x='450' y='310' text-anchor='middle' class='small'>both</text>
  <text x='630' y='310' text-anchor='middle' class='small'>only</text>
</svg>\n"""
    path.write_text(svg)


def make_scatter_svg(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width, height = 950, 700
    ml, mr, mt, mb = 90, 40, 70, 90
    plot_w, plot_h = width - ml - mr, height - mt - mb
    colors = {
        "packet-protocol-codec": "#1f77b4",
        "connection-session-login": "#ff7f0e",
        "config-plugin-command": "#2ca02c",
        "server-backend-routing": "#d62728",
        "api": "#9467bd",
        "native": "#8c564b",
        "utility-other": "#7f7f7f",
    }
    pts = []
    for r in rows:
        if r["metric"] != "LINE":
            continue
        try:
            x = float(r["aflnet_24h_pct"])
            y = float(r["jazzer_any_pct"])
        except Exception:
            continue
        if math.isnan(x) or math.isnan(y):
            continue
        pts.append((x, y, str(r["sourcefile"]), str(r["category"])))

    def sx(x: float) -> float:
        return ml + x * plot_w
    def sy(y: float) -> float:
        return mt + (1-y) * plot_h

    elements = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<rect width='100%' height='100%' fill='white'/>",
        "<style>text{font-family:Arial,sans-serif}.title{font-size:24px;font-weight:bold}.axis{font-size:15px}.legend{font-size:13px}</style>",
        f"<text x='{width/2}' y='35' text-anchor='middle' class='title'>Coverage depth by class (AFLNet vs Jazzer)</text>",
        f"<line x1='{ml}' y1='{mt+plot_h}' x2='{ml+plot_w}' y2='{mt+plot_h}' stroke='black'/>",
        f"<line x1='{ml}' y1='{mt}' x2='{ml}' y2='{mt+plot_h}' stroke='black'/>",
    ]
    for t in [0, .25, .5, .75, 1.0]:
        elements.append(f"<line x1='{sx(t)}' y1='{mt+plot_h}' x2='{sx(t)}' y2='{mt+plot_h+6}' stroke='black'/>")
        elements.append(f"<text x='{sx(t)}' y='{mt+plot_h+25}' text-anchor='middle' class='axis'>{int(t*100)}%</text>")
        elements.append(f"<line x1='{ml-6}' y1='{sy(t)}' x2='{ml}' y2='{sy(t)}' stroke='black'/>")
        elements.append(f"<text x='{ml-12}' y='{sy(t)+5}' text-anchor='end' class='axis'>{int(t*100)}%</text>")
    elements.append(f"<text x='{ml+plot_w/2}' y='{height-25}' text-anchor='middle' class='axis'>AFLNet 24h LINE coverage %</text>")
    elements.append(f"<text x='24' y='{mt+plot_h/2}' text-anchor='middle' class='axis' transform='rotate(-90 24 {mt+plot_h/2})'>Jazzer max LINE coverage %</text>")
    elements.append(f"<line x1='{ml}' y1='{mt+plot_h}' x2='{ml+plot_w}' y2='{mt}' stroke='#aaa' stroke-dasharray='4,4'/>")
    for x, y, name, cat in pts:
        c = colors.get(cat, "#7f7f7f")
        elements.append(f"<circle cx='{sx(x):.1f}' cy='{sy(y):.1f}' r='4' fill='{c}' fill-opacity='0.75'><title>{name}: AFLNet {x*100:.1f}%, Jazzer {y*100:.1f}%</title></circle>")
    lx, ly = ml + plot_w - 230, mt + 20
    for i, (cat, c) in enumerate(colors.items()):
        y = ly + i*19
        elements.append(f"<circle cx='{lx}' cy='{y}' r='5' fill='{c}'/>")
        elements.append(f"<text x='{lx+12}' y='{y+5}' class='legend'>{cat}</text>")
    elements.append("</svg>")
    path.write_text("\n".join(elements) + "\n")


def parse_jazzer_stats(path: Path) -> dict[str, str]:
    out = {}
    if not path.exists():
        return out
    text = path.read_text(errors="replace")
    matches = re.findall(r"Done\s+(\d+)\s+runs\s+in\s+(\d+)\s+second", text)
    if matches:
        out["executed_units"], out["seconds"] = matches[-1]
    for key, rx in {
        "average_exec_per_sec": r"stat::average_exec_per_sec:\s+(\d+)",
        "new_units_added": r"stat::new_units_added:\s+(\d+)",
        "peak_rss_mb": r"stat::peak_rss_mb:\s+(\d+)",
    }.items():
        matches = re.findall(rx, text)
        if matches:
            out[key] = matches[-1]
    return out


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    src_idx = source_index()

    jazzer_state = parse_jazzer_quick(JAZZER_STATEFUL)
    jazzer_stateless = parse_jazzer_quick(JAZZER_STATELESS)
    aflnet24 = parse_jacoco_xml(AFLNET_24H_XML)
    aflnet11 = parse_jacoco_xml(AFLNET_11H_XML)
    baseline = parse_jacoco_xml(BASELINE_XML)

    project_sources = set(src_idx)
    # Sourcefile-level comparison is filename-based because Jazzer quick coverage omits packages.
    sources = sorted((set(jazzer_state) | set(jazzer_stateless) | set(aflnet24) | set(aflnet11) | set(baseline)) & project_sources)

    rows: list[dict[str, object]] = []
    for s in sources:
        paths = src_idx.get(s, [])
        cat = category_for(s, paths)
        for metric in ["LINE", "BRANCH"]:
            js = jazzer_state.get(s, {}).get(metric, Counter(0, 0))
            jt = jazzer_stateless.get(s, {}).get(metric, Counter(0, 0))
            ja = max_counter(js, jt)
            a24 = aflnet24.get(s, {}).get(metric, Counter(0, 0))
            a11 = aflnet11.get(s, {}).get(metric, Counter(0, 0))
            bl = baseline.get(s, {}).get(metric, Counter(0, 0))
            if max(js.total, jt.total, a24.total, a11.total, bl.total) == 0:
                continue
            rows.append({
                "sourcefile": s,
                "category": cat,
                "paths": ";".join(paths[:5]),
                "path_count": len(paths),
                "metric": metric,
                "jazzer_stateful_covered": js.covered,
                "jazzer_stateful_total": js.total,
                "jazzer_stateful_pct": js.pct if js.pct is not None else "",
                "jazzer_stateless_covered": jt.covered,
                "jazzer_stateless_total": jt.total,
                "jazzer_stateless_pct": jt.pct if jt.pct is not None else "",
                "jazzer_any_covered": ja.covered,
                "jazzer_any_total": ja.total,
                "jazzer_any_pct": ja.pct if ja.pct is not None else "",
                "aflnet_24h_covered": a24.covered,
                "aflnet_24h_total": a24.total,
                "aflnet_24h_pct": a24.pct if a24.pct is not None else "",
                "aflnet_11h_epoch_covered": a11.covered,
                "aflnet_11h_epoch_total": a11.total,
                "aflnet_11h_epoch_pct": a11.pct if a11.pct is not None else "",
                "baseline_covered": bl.covered,
                "baseline_total": bl.total,
                "baseline_pct": bl.pct if bl.pct is not None else "",
                "jazzer_nonzero": ja.covered > 0,
                "aflnet_24h_nonzero": a24.covered > 0,
                "delta_jazzer_minus_aflnet_24h": (ja.pct or 0) - (a24.pct or 0),
            })

    # Exclude Jazzer harness entrypoints from product-code comparisons.
    product_rows = [r for r in rows if r["category"] != "jazzer-fuzz-target"]
    fields = list(product_rows[0].keys()) if product_rows else []
    write_csv(OUT / "sourcefile-coverage-comparison.csv", product_rows, fields)
    line_rows = [r for r in product_rows if r["metric"] == "LINE"]
    branch_rows = [r for r in product_rows if r["metric"] == "BRANCH"]
    jazzer_nonzero = {r["sourcefile"] for r in line_rows if r["jazzer_nonzero"]}
    aflnet_nonzero = {r["sourcefile"] for r in line_rows if r["aflnet_24h_nonzero"]}
    both = jazzer_nonzero & aflnet_nonzero
    only_j = jazzer_nonzero - aflnet_nonzero
    only_a = aflnet_nonzero - jazzer_nonzero

    branch_j = {r["sourcefile"] for r in branch_rows if r["jazzer_nonzero"]}
    branch_a = {r["sourcefile"] for r in branch_rows if r["aflnet_24h_nonzero"]}

    venn_rows = [
        ["Line-covered classes", len(only_j), len(both), len(only_a), len(jazzer_nonzero), len(aflnet_nonzero)],
        ["Branch-covered classes", len(branch_j - branch_a), len(branch_j & branch_a), len(branch_a - branch_j), len(branch_j), len(branch_a)],
    ]
    write_md_table(OUT / "coverage-venn-summary.md", ["metric", "jazzer_only", "both", "aflnet_only", "jazzer_total", "aflnet_total"], venn_rows)
    write_csv(OUT / "coverage-venn-summary.csv", [dict(zip(["metric", "jazzer_only", "both", "aflnet_only", "jazzer_total", "aflnet_total"], r)) for r in venn_rows], ["metric", "jazzer_only", "both", "aflnet_only", "jazzer_total", "aflnet_total"])
    make_venn_svg(OUT / "coverage-venn-line.svg", "Classes with line coverage", "Jazzer", "AFLNet 24h", len(only_j), len(both), len(only_a))
    make_venn_svg(OUT / "coverage-venn-branch.svg", "Classes with branch coverage", "Jazzer", "AFLNet 24h", len(branch_j - branch_a), len(branch_j & branch_a), len(branch_a - branch_j))

    make_scatter_svg(OUT / "coverage-depth-scatter.svg", line_rows)

    jazzer_favored = sorted([r for r in line_rows if r["jazzer_any_total"] and r["aflnet_24h_total"]], key=lambda r: float(r["delta_jazzer_minus_aflnet_24h"]), reverse=True)[:30]
    aflnet_favored = sorted([r for r in line_rows if r["jazzer_any_total"] and r["aflnet_24h_total"]], key=lambda r: float(r["delta_jazzer_minus_aflnet_24h"]))[:30]
    diff_fields = ["sourcefile", "category", "jazzer_any_covered", "jazzer_any_total", "jazzer_any_pct", "aflnet_24h_covered", "aflnet_24h_total", "aflnet_24h_pct", "delta_jazzer_minus_aflnet_24h"]
    write_csv(OUT / "top-jazzer-favored-sourcefiles.csv", jazzer_favored, diff_fields)
    write_csv(OUT / "top-aflnet-favored-sourcefiles.csv", aflnet_favored, diff_fields)
    write_md_table(OUT / "top-jazzer-favored-sourcefiles.md", diff_fields, [[r.get(f, "") for f in diff_fields] for r in jazzer_favored])
    write_md_table(OUT / "top-aflnet-favored-sourcefiles.md", diff_fields, [[r.get(f, "") for f in diff_fields] for r in aflnet_favored])

    # Buckets
    bucket: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for r in line_rows:
        b = str(r["category"])
        bucket[b]["sourcefiles"] += 1
        bucket[b]["jazzer_nonzero_sourcefiles"] += int(bool(r["jazzer_nonzero"]))
        bucket[b]["aflnet_nonzero_sourcefiles"] += int(bool(r["aflnet_24h_nonzero"]))
        bucket[b]["jazzer_covered_lines"] += int(r["jazzer_any_covered"])
        bucket[b]["jazzer_total_lines"] += int(r["jazzer_any_total"])
        bucket[b]["aflnet_covered_lines"] += int(r["aflnet_24h_covered"])
        bucket[b]["aflnet_total_lines"] += int(r["aflnet_24h_total"])
    bucket_rows = []
    for b, d in sorted(bucket.items()):
        bucket_rows.append({
            "category": b,
            "sourcefiles": d["sourcefiles"],
            "jazzer_nonzero_sourcefiles": d["jazzer_nonzero_sourcefiles"],
            "aflnet_nonzero_sourcefiles": d["aflnet_nonzero_sourcefiles"],
            "jazzer_line_covered": d["jazzer_covered_lines"],
            "jazzer_line_total": d["jazzer_total_lines"],
            "jazzer_line_pct": f"{100*d['jazzer_covered_lines']/d['jazzer_total_lines']:.1f}%" if d["jazzer_total_lines"] else "NA",
            "aflnet_line_covered": d["aflnet_covered_lines"],
            "aflnet_line_total": d["aflnet_total_lines"],
            "aflnet_line_pct": f"{100*d['aflnet_covered_lines']/d['aflnet_total_lines']:.1f}%" if d["aflnet_total_lines"] else "NA",
        })
    bucket_fields = list(bucket_rows[0].keys()) if bucket_rows else []
    write_csv(OUT / "domain-bucket-coverage.csv", bucket_rows, bucket_fields)
    write_md_table(OUT / "domain-bucket-coverage.md", bucket_fields, [[r.get(f, "") for f in bucket_fields] for r in bucket_rows])

    # Fault/workflow tables from existing logs/summaries.
    a24s, a11s = read_kv(AFLNET_24H_SUMMARY), read_kv(AFLNET_11H_SUMMARY)
    a24f, a11f = read_fuzzer_stats(AFLNET_24H_STATS), read_fuzzer_stats(AFLNET_11H_STATS)
    js, jl = parse_jazzer_stats(JAZZER_STATEFUL_LOG), parse_jazzer_stats(JAZZER_STATELESS_LOG)
    fault_rows = [
        {"engine": "AFLNet", "run": "24h state-aware", "execs": a24f.get("execs_done", ""), "exec_per_sec": a24f.get("execs_per_sec", ""), "queue_or_corpus": a24f.get("paths_total", ""), "crashes_or_findings": a24f.get("unique_crashes", ""), "hangs": a24f.get("unique_hangs", ""), "artifact_semantics": "live network queue/crash/hang artifacts"},
        {"engine": "AFLNet", "run": "11h campaign-epoch", "execs": a11f.get("execs_done", ""), "exec_per_sec": a11f.get("execs_per_sec", ""), "queue_or_corpus": a11f.get("paths_total", ""), "crashes_or_findings": a11f.get("unique_crashes", ""), "hangs": a11f.get("unique_hangs", ""), "artifact_semantics": "live network queue/crash/hang artifacts"},
        {"engine": "Jazzer", "run": "stateful", "execs": js.get("executed_units", ""), "exec_per_sec": js.get("average_exec_per_sec", ""), "queue_or_corpus": js.get("new_units_added", ""), "crashes_or_findings": "fault signatures/reproducers", "hangs": "NA", "artifact_semantics": "in-process JVM corpus/fault artifacts"},
        {"engine": "Jazzer", "run": "stateless", "execs": jl.get("executed_units", ""), "exec_per_sec": jl.get("average_exec_per_sec", ""), "queue_or_corpus": jl.get("new_units_added", ""), "crashes_or_findings": "fault signatures/reproducers", "hangs": "NA", "artifact_semantics": "in-process JVM corpus/fault artifacts"},
    ]
    fault_fields = ["engine", "run", "execs", "exec_per_sec", "queue_or_corpus", "crashes_or_findings", "hangs", "artifact_semantics"]
    write_csv(OUT / "fault-signal-throughput-comparison.csv", fault_rows, fault_fields)
    write_md_table(OUT / "fault-signal-throughput-comparison.md", fault_fields, [[r.get(f, "") for f in fault_fields] for r in fault_rows])

    workflow_rows = [
        ["AFLNet state-aware 10m whole", "PASS", "PASS", "comprehensive 20260508T092301Z"],
        ["AFLNet code-only 10m whole", "PASS", "PASS", "comprehensive 20260508T092301Z"],
        ["AFLNet state-only 10m whole", "PASS", "PASS", "comprehensive 20260508T092301Z"],
        ["AFLNet state-aware 10m campaign-epoch", "PASS", "PASS", "comprehensive 20260508T092301Z"],
        ["Jazzer stateful 3m", "PASS", "PASS", "rerun 20260508T162645Z"],
        ["Jazzer stateless 3m", "PASS", "PASS", "rerun 20260508T162645Z"],
        ["Jazzer+JaCoCo stateful 3m", "PASS", "PASS", "rerun 20260508T162645Z"],
        ["Jazzer+JaCoCo stateless 3m", "PASS", "PASS", "rerun 20260508T162645Z"],
    ]
    write_md_table(OUT / "native-docker-workflow-matrix.md", ["workflow", "native", "docker", "evidence"], workflow_rows)
    write_csv(OUT / "native-docker-workflow-matrix.csv", [dict(zip(["workflow", "native", "docker", "evidence"], r)) for r in workflow_rows], ["workflow", "native", "docker", "evidence"])

    # README/index.
    readme = f"""# Cross-Fuzzer Report Artifacts

Generated from existing AFLNet JaCoCo XML and Joshi-provided Jazzer quick-coverage artifacts. No new fuzzing was run by this generator.

## Key outputs

- `coverage-venn-summary.md/csv` and `coverage-venn-line.svg`, `coverage-venn-branch.svg`
- `coverage-depth-scatter.svg`
- `top-jazzer-favored-sourcefiles.md/csv`
- `top-aflnet-favored-sourcefiles.md/csv`
- `domain-bucket-coverage.md/csv`
- `fault-signal-throughput-comparison.md/csv`
- `native-docker-workflow-matrix.md/csv`
- `sourcefile-coverage-comparison.csv`

## Important caveat

Jazzer quick coverage is filename-level. JaCoCo XML is package+sourcefile-level. This comparison maps Jazzer filenames to Velocity project source filenames; duplicate filenames are aggregated/flagged via `path_count` in the CSV. Use this for sourcefile/class-level story, not method/line-exact intersection.

## Headline counts

- Line-covered classes: Jazzer-only={len(only_j)}, both={len(both)}, AFLNet-only={len(only_a)}.
- Branch-covered classes: Jazzer-only={len(branch_j-branch_a)}, both={len(branch_j & branch_a)}, AFLNet-only={len(branch_a-branch_j)}.
"""
    (OUT / "README.md").write_text(readme)

    print(f"out={OUT}")
    print(f"line_jazzer_only={len(only_j)}")
    print(f"line_both={len(both)}")
    print(f"line_aflnet_only={len(only_a)}")
    print(f"branch_jazzer_only={len(branch_j-branch_a)}")
    print(f"branch_both={len(branch_j & branch_a)}")
    print(f"branch_aflnet_only={len(branch_a-branch_j)}")
    print(f"sourcefiles={len(sources)} rows={len(rows)}")


if __name__ == "__main__":
    main()
