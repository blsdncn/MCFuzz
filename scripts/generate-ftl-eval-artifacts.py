#!/usr/bin/env python3
from __future__ import annotations

import csv
import math
import statistics
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
EVAL_ROOT = ROOT / "eval-runs"
FTL_ROOT = ROOT / "FTL"


@dataclass
class RunSpec:
    slug: str
    label: str
    short_label: str
    mode: str
    color: str
    completed: bool
    kind: str  # matrix12h or live24h


RUN_SPECS = [
    RunSpec("20260503T054121Z-state-aware-43200s", "12h state+coverage", "12h-sc", "state-aware", "#1f77b4", True, "matrix12h"),
    RunSpec("20260503T054505Z-code-only-43200s", "12h coverage-only", "12h-c", "code-only", "#ff7f0e", True, "matrix12h"),
    RunSpec("20260503T054506Z-state-only-43200s", "12h state-only", "12h-s", "state-only", "#2ca02c", True, "matrix12h"),
    RunSpec("20260505T045009Z-state-aware-86400s", "24h state+coverage (completed PASS)", "24h-sc", "state-aware", "#9467bd", False, "live24h"),
]

PATH_MILESTONES = [10, 50, 100, 150, 200, 250, 300]
HANG_MILESTONES = [1, 10, 50, 100, 250, 500]
STATE_NODE_MILESTONES = [4, 8, 12, 16]
STATE_EDGE_MILESTONES = [3, 8, 16, 24]
HOURLY_MARKS = list(range(0, 13))


def read_kv_equals(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def read_fuzzer_stats(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text().splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip()
    return data


def read_plot_data(path: Path) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    if not path.exists():
        return rows
    with path.open() as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 13:
                continue
            map_pct = parts[6].rstrip("%")
            rows.append({
                "unix_time": float(parts[0]),
                "cycles_done": float(parts[1]),
                "cur_path": float(parts[2]),
                "paths_total": float(parts[3]),
                "pending_total": float(parts[4]),
                "pending_favs": float(parts[5]),
                "map_size_pct": float(map_pct),
                "unique_crashes": float(parts[7]),
                "unique_hangs": float(parts[8]),
                "max_depth": float(parts[9]),
                "execs_per_sec": float(parts[10]),
                "n_nodes": float(parts[11]),
                "n_edges": float(parts[12]),
            })
    if rows:
        start = rows[0]["unix_time"]
        for row in rows:
            row["hours_since_start"] = (row["unix_time"] - start) / 3600.0
    return rows


def iso(ts: float | int | None) -> str:
    if ts is None:
        return "unavailable"
    return datetime.fromtimestamp(float(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_float(value: str | None) -> float | None:
    if value is None or value == "" or value == "unavailable":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_int(value: str | None) -> int | None:
    if value is None or value == "" or value == "unavailable":
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def format_num(value: float | int | None, digits: int = 2) -> str:
    if value is None:
        return "NA"
    if isinstance(value, int):
        return str(value)
    if math.isfinite(value) and abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return f"{value:.{digits}f}"


def write_csv(path: Path, rows: list[dict[str, object]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_markdown_table(path: Path, headers: list[str], rows: list[list[object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for row in rows:
        lines.append("| " + " | ".join(str(x) for x in row) + " |")
    path.write_text("\n".join(lines) + "\n")


def line_count(path: Path) -> int:
    if not path.exists():
        return 0
    with path.open() as f:
        return sum(1 for _ in f)


def parse_jacoco_xml(xml_path: Path) -> dict[str, int | float]:
    root = ET.parse(xml_path).getroot()
    covered_classes = 0
    covered_packages = set()
    for package_node in root.findall("package"):
        package_name = package_node.attrib.get("name", "")
        for class_node in package_node.findall("class"):
            covered = False
            for counter in class_node.findall("counter"):
                if counter.attrib.get("type") == "LINE" and int(counter.attrib.get("covered", "0")) > 0:
                    covered = True
                    break
            if covered:
                covered_classes += 1
                covered_packages.add(package_name)
    return {
        "xml_classes_with_covered_lines": covered_classes,
        "xml_packages_with_covered_lines": len(covered_packages),
    }


def sample_lines(path: Path, count: int = 12) -> list[str]:
    if not path.exists():
        return []
    out = []
    with path.open() as f:
        for idx, line in enumerate(f):
            if idx >= count:
                break
            out.append(line.rstrip())
    return out


def milestone_time(rows: list[dict[str, float]], key: str, threshold: float) -> float | None:
    for row in rows:
        if row.get(key, 0.0) >= threshold:
            return row.get("hours_since_start")
    return None


def hourly_snapshot(rows: list[dict[str, float]], hour_mark: int) -> dict[str, float] | None:
    if not rows:
        return None
    chosen = None
    for row in rows:
        if row["hours_since_start"] <= hour_mark + 1e-9:
            chosen = row
        else:
            break
    return chosen


def make_svg_line_chart(path: Path, title: str, series: list[tuple[str, str, list[tuple[float, float | None]]]], y_label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width, height = 1100, 650
    ml, mr, mt, mb = 80, 30, 60, 70
    all_points = [(x, y) for _, _, pts in series for x, y in pts if y is not None]
    if not all_points:
        path.write_text("<svg xmlns='http://www.w3.org/2000/svg' width='1100' height='650'></svg>\n")
        return
    min_x = min(x for x, _ in all_points)
    max_x = max(x for x, _ in all_points)
    min_y = min(y for _, y in all_points)
    max_y = max(y for _, y in all_points)
    if max_x == min_x:
        max_x = min_x + 1
    if max_y == min_y:
        max_y = min_y + 1
    if min_y > 0:
        min_y = 0

    def sx(x: float) -> float:
        return ml + (x - min_x) / (max_x - min_x) * (width - ml - mr)

    def sy(y: float) -> float:
        return height - mb - (y - min_y) / (max_y - min_y) * (height - mt - mb)

    elements = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<style>text{font-family:Arial,Helvetica,sans-serif;font-size:14px} .title{font-size:22px;font-weight:bold} .axis{stroke:#333;stroke-width:1} .grid{stroke:#ddd;stroke-width:1} .legend{font-size:13px}</style>",
        f"<text x='{width/2}' y='30' text-anchor='middle' class='title'>{title}</text>",
    ]
    # grid and y ticks
    for i in range(6):
        val = min_y + (max_y - min_y) * i / 5
        y = sy(val)
        elements.append(f"<line x1='{ml}' y1='{y:.2f}' x2='{width-mr}' y2='{y:.2f}' class='grid'/>")
        elements.append(f"<text x='{ml-10}' y='{y+5:.2f}' text-anchor='end'>{val:.1f}</text>")
    # x ticks
    x_ticks = max(2, min(10, int(math.ceil(max_x - min_x)) + 1))
    for i in range(x_ticks):
        frac = i / (x_ticks - 1) if x_ticks > 1 else 0
        val = min_x + (max_x - min_x) * frac
        x = sx(val)
        elements.append(f"<line x1='{x:.2f}' y1='{mt}' x2='{x:.2f}' y2='{height-mb}' class='grid'/>")
        elements.append(f"<text x='{x:.2f}' y='{height-mb+25}' text-anchor='middle'>{val:.1f}</text>")
    elements.append(f"<line x1='{ml}' y1='{height-mb}' x2='{width-mr}' y2='{height-mb}' class='axis'/>")
    elements.append(f"<line x1='{ml}' y1='{mt}' x2='{ml}' y2='{height-mb}' class='axis'/>")
    elements.append(f"<text x='{width/2}' y='{height-20}' text-anchor='middle'>hours since campaign start</text>")
    elements.append(f"<text x='20' y='{height/2}' transform='rotate(-90 20 {height/2})' text-anchor='middle'>{y_label}</text>")

    for idx, (label, color, pts) in enumerate(series):
        coords = []
        for x, y in pts:
            if y is None:
                continue
            coords.append(f"{sx(x):.2f},{sy(y):.2f}")
        if coords:
            elements.append(f"<polyline fill='none' stroke='{color}' stroke-width='2.5' points='{' '.join(coords)}'/>")
        lx = width - mr - 240
        ly = mt + 10 + idx * 22
        elements.append(f"<line x1='{lx}' y1='{ly}' x2='{lx+24}' y2='{ly}' stroke='{color}' stroke-width='3'/>")
        elements.append(f"<text x='{lx+30}' y='{ly+5}' class='legend'>{label}</text>")
    elements.append("</svg>\n")
    path.write_text("\n".join(elements))


def make_svg_bar_chart(path: Path, title: str, items: list[tuple[str, str, float]], y_label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width, height = 1000, 650
    ml, mr, mt, mb = 80, 30, 60, 90
    max_y = max((v for _, _, v in items), default=1)
    if max_y <= 0:
        max_y = 1
    def sy(y: float) -> float:
        return height - mb - y / max_y * (height - mt - mb)
    elements = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<style>text{font-family:Arial,Helvetica,sans-serif;font-size:14px} .title{font-size:22px;font-weight:bold} .axis{stroke:#333;stroke-width:1} .grid{stroke:#ddd;stroke-width:1}</style>",
        f"<text x='{width/2}' y='30' text-anchor='middle' class='title'>{title}</text>",
    ]
    for i in range(6):
        val = max_y * i / 5
        y = sy(val)
        elements.append(f"<line x1='{ml}' y1='{y:.2f}' x2='{width-mr}' y2='{y:.2f}' class='grid'/>")
        elements.append(f"<text x='{ml-10}' y='{y+5:.2f}' text-anchor='end'>{val:.1f}</text>")
    elements.append(f"<line x1='{ml}' y1='{height-mb}' x2='{width-mr}' y2='{height-mb}' class='axis'/>")
    elements.append(f"<line x1='{ml}' y1='{mt}' x2='{ml}' y2='{height-mb}' class='axis'/>")
    elements.append(f"<text x='20' y='{height/2}' transform='rotate(-90 20 {height/2})' text-anchor='middle'>{y_label}</text>")
    inner_width = width - ml - mr
    bar_width = inner_width / max(1, len(items)) * 0.55
    gap = inner_width / max(1, len(items))
    for idx, (label, color, val) in enumerate(items):
        x = ml + idx * gap + (gap - bar_width) / 2
        y = sy(val)
        h = height - mb - y
        elements.append(f"<rect x='{x:.2f}' y='{y:.2f}' width='{bar_width:.2f}' height='{h:.2f}' fill='{color}'/>")
        elements.append(f"<text x='{x + bar_width/2:.2f}' y='{height-mb+20}' text-anchor='middle'>{label}</text>")
        elements.append(f"<text x='{x + bar_width/2:.2f}' y='{y-8:.2f}' text-anchor='middle'>{val:.1f}</text>")
    elements.append("</svg>\n")
    path.write_text("\n".join(elements))


def make_svg_scatter(path: Path, title: str, items: list[tuple[str, str, float, float]], x_label: str, y_label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width, height = 1000, 650
    ml, mr, mt, mb = 80, 30, 60, 80
    min_x = 0
    max_x = max((x for _, _, x, _ in items), default=1)
    min_y = 0
    max_y = max((y for _, _, _, y in items), default=1)
    if max_x <= 0:
        max_x = 1
    if max_y <= 0:
        max_y = 1
    def sx(x: float) -> float:
        return ml + (x - min_x) / (max_x - min_x) * (width - ml - mr)
    def sy(y: float) -> float:
        return height - mb - (y - min_y) / (max_y - min_y) * (height - mt - mb)
    elements = [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<style>text{font-family:Arial,Helvetica,sans-serif;font-size:14px} .title{font-size:22px;font-weight:bold} .axis{stroke:#333;stroke-width:1} .grid{stroke:#ddd;stroke-width:1}</style>",
        f"<text x='{width/2}' y='30' text-anchor='middle' class='title'>{title}</text>",
    ]
    for i in range(6):
        xv = max_x * i / 5
        x = sx(xv)
        elements.append(f"<line x1='{x:.2f}' y1='{mt}' x2='{x:.2f}' y2='{height-mb}' class='grid'/>")
        elements.append(f"<text x='{x:.2f}' y='{height-mb+22}' text-anchor='middle'>{xv:.0f}</text>")
        yv = max_y * i / 5
        y = sy(yv)
        elements.append(f"<line x1='{ml}' y1='{y:.2f}' x2='{width-mr}' y2='{y:.2f}' class='grid'/>")
        elements.append(f"<text x='{ml-10}' y='{y+5:.2f}' text-anchor='end'>{yv:.0f}</text>")
    elements.append(f"<line x1='{ml}' y1='{height-mb}' x2='{width-mr}' y2='{height-mb}' class='axis'/>")
    elements.append(f"<line x1='{ml}' y1='{mt}' x2='{ml}' y2='{height-mb}' class='axis'/>")
    elements.append(f"<text x='{width/2}' y='{height-20}' text-anchor='middle'>{x_label}</text>")
    elements.append(f"<text x='20' y='{height/2}' transform='rotate(-90 20 {height/2})' text-anchor='middle'>{y_label}</text>")
    for label, color, x, y in items:
        cx, cy = sx(x), sy(y)
        elements.append(f"<circle cx='{cx:.2f}' cy='{cy:.2f}' r='7' fill='{color}'/>")
        elements.append(f"<text x='{cx+10:.2f}' y='{cy-8:.2f}'>{label}</text>")
    elements.append("</svg>\n")
    path.write_text("\n".join(elements))


def sanitize_row(row: dict[str, object]) -> dict[str, object]:
    out = {}
    for k, v in row.items():
        out[k] = v if v is not None else ""
    return out


def main() -> None:
    for sub in ["tables", "figures", "listings", "data"]:
        (FTL_ROOT / sub).mkdir(parents=True, exist_ok=True)

    runs = []
    for spec in RUN_SPECS:
        run_root = EVAL_ROOT / spec.slug
        campaign = run_root / "campaign"
        run_summary = read_kv_equals(campaign / "run-summary.txt")
        eval_summary = read_kv_equals(run_root / "eval-summary.txt")
        comparison = read_kv_equals(campaign / "coverage" / "comparison-vs-latest-baseline.txt")
        hang_analysis = read_kv_equals(campaign / "hang-analysis.txt")
        plot_rows = read_plot_data(campaign / "aflnet-out" / "plot_data")
        line_details = campaign / "coverage" / "line-details"
        jacoco_xml = campaign / "coverage" / "jacoco.xml"
        jacoco_xml_summary = parse_jacoco_xml(jacoco_xml) if jacoco_xml.exists() else {}
        info = {
            "spec": spec,
            "run_root": run_root,
            "campaign_dir": campaign,
            "run_summary": run_summary,
            "eval_summary": eval_summary,
            "comparison": comparison,
            "hang_analysis": hang_analysis,
            "plot_rows": plot_rows,
            "line_details": line_details,
            "jacoco_xml_summary": jacoco_xml_summary,
        }
        runs.append(info)
        # per-run data csv
        if plot_rows:
            csv_rows = []
            start = plot_rows[0]["unix_time"]
            final_paths = plot_rows[-1]["paths_total"] or 1
            final_hangs = max(1.0, plot_rows[-1]["unique_hangs"])
            for row in plot_rows:
                csv_rows.append(sanitize_row({
                    "label": spec.label,
                    "short_label": spec.short_label,
                    "mode": spec.mode,
                    "unix_time": int(row["unix_time"]),
                    "iso_time": iso(row["unix_time"]),
                    "seconds_since_start": int(row["unix_time"] - start),
                    "hours_since_start": f"{row['hours_since_start']:.4f}",
                    "paths_total": int(row["paths_total"]),
                    "pending_total": int(row["pending_total"]),
                    "bitmap_cvg_percent": f"{row['map_size_pct']:.4f}",
                    "unique_hangs": int(row["unique_hangs"]),
                    "unique_crashes": int(row["unique_crashes"]),
                    "max_depth": int(row["max_depth"]),
                    "execs_per_sec": f"{row['execs_per_sec']:.4f}",
                    "n_nodes": int(row["n_nodes"]),
                    "n_edges": int(row["n_edges"]),
                    "paths_total_fraction_of_final": f"{(row['paths_total']/final_paths):.6f}",
                    "unique_hangs_fraction_of_final": f"{(row['unique_hangs']/final_hangs):.6f}",
                }))
            write_csv(FTL_ROOT / "data" / f"{spec.slug}-timeseries.csv", csv_rows, list(csv_rows[0].keys()))

    completed = [r for r in runs if r["spec"].completed]
    live = [r for r in runs if not r["spec"].completed]

    # Run manifest
    manifest_rows = []
    for r in runs:
        spec = r["spec"]
        summary = r["run_summary"]
        manifest_rows.append({
            "slug": spec.slug,
            "label": spec.label,
            "short_label": spec.short_label,
            "mode": spec.mode,
            "kind": spec.kind,
            "completed": "yes" if spec.completed else "no",
            "campaign_status": summary.get("campaign_status", "in-progress"),
            "campaign_seconds": summary.get("campaign_seconds", "in-progress"),
            "campaign_dir": str(r["campaign_dir"]),
            "report": str(r["campaign_dir"] / "campaign-report.md"),
            "comparison": str(r["campaign_dir"] / "coverage" / "comparison-vs-latest-baseline.txt"),
        })
    write_csv(FTL_ROOT / "tables" / "run-manifest.csv", [sanitize_row(r) for r in manifest_rows], list(manifest_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "run-manifest.md",
        ["label", "mode", "kind", "completed", "campaign_status", "campaign_seconds", "campaign_dir"],
        [[r["label"], r["mode"], r["kind"], r["completed"], r["campaign_status"], r["campaign_seconds"], r["campaign_dir"]] for r in manifest_rows],
    )

    # Final matrix summary table
    final_rows = []
    for r in completed:
        spec = r["spec"]
        s = r["run_summary"]
        h = r["hang_analysis"]
        c = r["comparison"]
        final_rows.append({
            "label": spec.label,
            "mode": spec.mode,
            "execs_done": parse_int(s.get("execs_done")),
            "execs_per_sec": parse_float(s.get("execs_per_sec")),
            "queue_count": parse_int(s.get("queue_count")),
            "queue_paths_found": parse_int(s.get("queue_paths_found")),
            "replayable_hangs": parse_int(s.get("replayable_hangs")),
            "hang_hash_uniques": parse_int(h.get("unique_hang_hash_count")),
            "line_covered_delta": parse_int(c.get("line_covered_delta")),
            "campaign_line_locations_covered": parse_int(c.get("campaign_line_locations_covered")),
            "classes_campaign_only": parse_int(c.get("classes_covered_by_campaign_not_baseline")),
            "target_failure_class": s.get("target_failure_class"),
        })
    write_csv(FTL_ROOT / "tables" / "final-matrix-summary.csv", [sanitize_row(r) for r in final_rows], list(final_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "final-matrix-summary.md",
        ["label", "execs_done", "execs_per_sec", "queue_paths_found", "replayable_hangs", "hang_hash_uniques", "line_covered_delta", "campaign_line_locations_covered", "classes_campaign_only", "target_failure_class"],
        [[r["label"], format_num(r["execs_done"]), format_num(r["execs_per_sec"]), format_num(r["queue_paths_found"]), format_num(r["replayable_hangs"]), format_num(r["hang_hash_uniques"]), format_num(r["line_covered_delta"]), format_num(r["campaign_line_locations_covered"]), format_num(r["classes_campaign_only"]), r["target_failure_class"]] for r in final_rows],
    )

    # Normalized table
    norm_rows = []
    for r in completed:
        spec = r["spec"]
        s = r["run_summary"]
        c = r["comparison"]
        secs = parse_float(s.get("campaign_seconds")) or 1.0
        execs = parse_float(s.get("execs_done")) or 0.0
        paths = parse_float(s.get("queue_paths_found")) or 0.0
        hangs = parse_float(s.get("replayable_hangs")) or 0.0
        line_delta = parse_float(c.get("line_covered_delta")) or 0.0
        norm_rows.append({
            "label": spec.label,
            "mode": spec.mode,
            "paths_per_hour": paths / (secs / 3600.0),
            "execs_per_hour": execs / (secs / 3600.0),
            "hangs_per_hour": hangs / (secs / 3600.0),
            "line_delta_per_hour": line_delta / (secs / 3600.0),
            "paths_per_10k_execs": (paths / execs * 10000.0) if execs else None,
            "hangs_per_10k_execs": (hangs / execs * 10000.0) if execs else None,
            "line_delta_per_10k_execs": (line_delta / execs * 10000.0) if execs else None,
        })
    write_csv(FTL_ROOT / "tables" / "normalized-comparison.csv", [sanitize_row(r) for r in norm_rows], list(norm_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "normalized-comparison.md",
        ["label", "paths_per_hour", "execs_per_hour", "hangs_per_hour", "line_delta_per_hour", "paths_per_10k_execs", "hangs_per_10k_execs", "line_delta_per_10k_execs"],
        [[r["label"], format_num(r["paths_per_hour"]), format_num(r["execs_per_hour"]), format_num(r["hangs_per_hour"]), format_num(r["line_delta_per_hour"]), format_num(r["paths_per_10k_execs"]), format_num(r["hangs_per_10k_execs"]), format_num(r["line_delta_per_10k_execs"])] for r in norm_rows],
    )

    # Feedback/state/edge table
    feedback_rows = []
    for r in completed:
        spec = r["spec"]
        s = r["run_summary"]
        feedback_rows.append({
            "label": spec.label,
            "feedback_type": s.get("aflnet_feedback_type"),
            "state_feedback_evidence": s.get("state_feedback_evidence"),
            "edge_feedback_evidence": s.get("edge_feedback_evidence"),
            "agent_engine": s.get("agent_engine"),
            "state_nodes_final": parse_int(s.get("state_coverage_final_nodes")) if s.get("state_coverage_final_nodes") else parse_int(s.get("state_coverage_nodes")),
            "state_edges_final": parse_int(s.get("state_coverage_final_edges")) if s.get("state_coverage_final_edges") else parse_int(s.get("state_coverage_edges")),
            "state_node_growth": parse_int(s.get("state_coverage_node_growth")),
            "state_edge_growth": parse_int(s.get("state_coverage_edge_growth")),
            "edge_nonzero_cells": parse_int(s.get("edge_coverage_nonzero_cells")),
            "edge_hit_count": parse_int(s.get("edge_coverage_hit_count")),
            "bitmap_changed_cells": parse_int(s.get("afl_fuzz_bitmap_changed_cells")),
            "bitmap_cvg_percent": parse_float(s.get("afl_bitmap_cvg_percent")),
        })
    write_csv(FTL_ROOT / "tables" / "feedback-state-edge.csv", [sanitize_row(r) for r in feedback_rows], list(feedback_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "feedback-state-edge.md",
        ["label", "feedback_type", "state_feedback_evidence", "edge_feedback_evidence", "agent_engine", "state_nodes_final", "state_edges_final", "state_node_growth", "state_edge_growth", "edge_nonzero_cells", "bitmap_changed_cells", "bitmap_cvg_percent"],
        [[r["label"], r["feedback_type"], r["state_feedback_evidence"], r["edge_feedback_evidence"], r["agent_engine"], format_num(r["state_nodes_final"]), format_num(r["state_edges_final"]), format_num(r["state_node_growth"]), format_num(r["state_edge_growth"]), format_num(r["edge_nonzero_cells"]), format_num(r["bitmap_changed_cells"]), format_num(r["bitmap_cvg_percent"])] for r in feedback_rows],
    )

    # JaCoCo comparison table
    jacoco_rows = []
    for r in completed:
        spec = r["spec"]
        c = r["comparison"]
        j = r["jacoco_xml_summary"]
        jacoco_rows.append({
            "label": spec.label,
            "line_covered_delta": parse_int(c.get("line_covered_delta")),
            "line_location_coverage_delta": parse_int(c.get("line_location_coverage_delta")),
            "campaign_line_locations_covered": parse_int(c.get("campaign_line_locations_covered")),
            "campaign_line_locations_covered_not_baseline": parse_int(c.get("line_locations_covered_by_campaign_not_baseline")),
            "campaign_classes_with_covered_lines": parse_int(c.get("campaign_classes_with_covered_lines")),
            "classes_campaign_not_baseline": parse_int(c.get("classes_covered_by_campaign_not_baseline")),
            "campaign_packages_with_covered_lines": parse_int(c.get("campaign_packages_with_covered_lines")),
            "packages_campaign_not_baseline": parse_int(c.get("packages_covered_by_campaign_not_baseline")),
            "campaign_line_location_coverage_percent": parse_float(c.get("campaign_line_location_coverage_percent")),
            "xml_classes_with_covered_lines": j.get("xml_classes_with_covered_lines"),
            "xml_packages_with_covered_lines": j.get("xml_packages_with_covered_lines"),
        })
    write_csv(FTL_ROOT / "tables" / "jacoco-comparison.csv", [sanitize_row(r) for r in jacoco_rows], list(jacoco_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "jacoco-comparison.md",
        ["label", "line_covered_delta", "line_location_coverage_delta", "campaign_line_locations_covered", "campaign_only_lines", "campaign_classes_with_covered_lines", "classes_campaign_not_baseline", "packages_campaign_not_baseline", "campaign_line_location_coverage_percent"],
        [[r["label"], format_num(r["line_covered_delta"]), format_num(r["line_location_coverage_delta"]), format_num(r["campaign_line_locations_covered"]), format_num(r["campaign_line_locations_covered_not_baseline"]), format_num(r["campaign_classes_with_covered_lines"]), format_num(r["classes_campaign_not_baseline"]), format_num(r["packages_campaign_not_baseline"]), format_num(r["campaign_line_location_coverage_percent"])] for r in jacoco_rows],
    )

    # Diagnostics table
    diag_rows = []
    for r in completed:
        spec = r["spec"]
        s = r["run_summary"]
        diag_rows.append({
            "label": spec.label,
            "fatal_velocity_log_count": parse_int(s.get("fatal_velocity_log_count")),
            "velocity_fatal_exception_count": parse_int(s.get("velocity_fatal_exception_count")),
            "handled_client_exception_count": parse_int(s.get("handled_client_exception_count")),
            "connection_reset_count": parse_int(s.get("connection_reset_count")),
            "timeout_count": parse_int(s.get("timeout_count")),
            "backend_or_session_error_count": parse_int(s.get("backend_or_session_error_count")),
            "target_failure_class": s.get("target_failure_class"),
            "velocity_alive_after_campaign": s.get("velocity_alive_after_campaign"),
        })
    write_csv(FTL_ROOT / "tables" / "target-diagnostics.csv", [sanitize_row(r) for r in diag_rows], list(diag_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "target-diagnostics.md",
        ["label", "fatal_velocity_log_count", "handled_client_exception_count", "connection_reset_count", "timeout_count", "backend_or_session_error_count", "target_failure_class", "velocity_alive_after_campaign"],
        [[r["label"], format_num(r["fatal_velocity_log_count"]), format_num(r["handled_client_exception_count"]), format_num(r["connection_reset_count"]), format_num(r["timeout_count"]), format_num(r["backend_or_session_error_count"]), r["target_failure_class"], r["velocity_alive_after_campaign"]] for r in diag_rows],
    )

    # Hang analysis table
    hang_rows = []
    for r in completed:
        spec = r["spec"]
        h = r["hang_analysis"]
        hang_rows.append({
            "label": spec.label,
            "replayable_hang_count": parse_int(h.get("replayable_hang_count")),
            "unique_hang_hash_count": parse_int(h.get("unique_hang_hash_count")),
            "duplicate_hang_count": parse_int(h.get("duplicate_hang_count")),
            "hang_size_min": parse_int(h.get("hang_size_min")),
            "hang_size_max": parse_int(h.get("hang_size_max")),
            "first_hang_artifact_time": h.get("first_hang_artifact_time"),
            "last_hang_artifact_time": h.get("last_hang_artifact_time"),
            "hang_cap_reached": "yes" if parse_int(h.get("replayable_hang_count")) == 500 else "no",
        })
    write_csv(FTL_ROOT / "tables" / "hang-analysis.csv", [sanitize_row(r) for r in hang_rows], list(hang_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "hang-analysis.md",
        ["label", "replayable_hang_count", "unique_hang_hash_count", "duplicate_hang_count", "hang_size_min", "hang_size_max", "first_hang_artifact_time", "last_hang_artifact_time", "hang_cap_reached"],
        [[r["label"], format_num(r["replayable_hang_count"]), format_num(r["unique_hang_hash_count"]), format_num(r["duplicate_hang_count"]), format_num(r["hang_size_min"]), format_num(r["hang_size_max"]), r["first_hang_artifact_time"], r["last_hang_artifact_time"], r["hang_cap_reached"]] for r in hang_rows],
    )

    # Line detail counts table
    line_rows = []
    for r in completed:
        spec = r["spec"]
        ld = r["line_details"]
        line_rows.append({
            "label": spec.label,
            "baseline_covered_lines_txt_count": line_count(ld / "baseline-covered-lines.txt"),
            "campaign_covered_lines_txt_count": line_count(ld / "campaign-covered-lines.txt"),
            "covered_by_both_lines_txt_count": line_count(ld / "covered-by-both-lines.txt"),
            "campaign_only_covered_lines_txt_count": line_count(ld / "campaign-only-covered-lines.txt"),
            "baseline_only_covered_lines_txt_count": line_count(ld / "baseline-only-covered-lines.txt"),
            "baseline_missed_only_lines_txt_count": line_count(ld / "baseline-missed-only-lines.txt"),
            "campaign_missed_only_lines_txt_count": line_count(ld / "campaign-missed-only-lines.txt"),
        })
    write_csv(FTL_ROOT / "tables" / "line-detail-counts.csv", [sanitize_row(r) for r in line_rows], list(line_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "line-detail-counts.md",
        ["label", "baseline_covered", "campaign_covered", "covered_by_both", "campaign_only_covered", "baseline_only_covered", "baseline_missed_only", "campaign_missed_only"],
        [[r["label"], format_num(r["baseline_covered_lines_txt_count"]), format_num(r["campaign_covered_lines_txt_count"]), format_num(r["covered_by_both_lines_txt_count"]), format_num(r["campaign_only_covered_lines_txt_count"]), format_num(r["baseline_only_covered_lines_txt_count"]), format_num(r["baseline_missed_only_lines_txt_count"]), format_num(r["campaign_missed_only_lines_txt_count"])] for r in line_rows],
    )

    # Milestones tables
    path_m_rows = []
    hang_m_rows = []
    state_m_rows = []
    for r in completed:
        spec = r["spec"]
        rows = r["plot_rows"]
        row = {"label": spec.label}
        for m in PATH_MILESTONES:
            row[f"paths_{m}_hours"] = milestone_time(rows, "paths_total", m)
        path_m_rows.append(row)
        row2 = {"label": spec.label}
        for m in HANG_MILESTONES:
            row2[f"hangs_{m}_hours"] = milestone_time(rows, "unique_hangs", m)
        hang_m_rows.append(row2)
        row3 = {"label": spec.label}
        for m in STATE_NODE_MILESTONES:
            row3[f"nodes_{m}_hours"] = milestone_time(rows, "n_nodes", m)
        for m in STATE_EDGE_MILESTONES:
            row3[f"edges_{m}_hours"] = milestone_time(rows, "n_edges", m)
        state_m_rows.append(row3)
    write_csv(FTL_ROOT / "tables" / "path-milestones.csv", [sanitize_row(r) for r in path_m_rows], list(path_m_rows[0].keys()))
    write_markdown_table(FTL_ROOT / "tables" / "path-milestones.md", ["label"] + [f"paths_{m}_hours" for m in PATH_MILESTONES], [[r["label"]] + [format_num(r.get(f"paths_{m}_hours")) for m in PATH_MILESTONES] for r in path_m_rows])
    write_csv(FTL_ROOT / "tables" / "hang-milestones.csv", [sanitize_row(r) for r in hang_m_rows], list(hang_m_rows[0].keys()))
    write_markdown_table(FTL_ROOT / "tables" / "hang-milestones.md", ["label"] + [f"hangs_{m}_hours" for m in HANG_MILESTONES], [[r["label"]] + [format_num(r.get(f"hangs_{m}_hours")) for m in HANG_MILESTONES] for r in hang_m_rows])
    write_csv(FTL_ROOT / "tables" / "state-milestones.csv", [sanitize_row(r) for r in state_m_rows], list(state_m_rows[0].keys()))
    state_headers = ["label"] + [f"nodes_{m}_hours" for m in STATE_NODE_MILESTONES] + [f"edges_{m}_hours" for m in STATE_EDGE_MILESTONES]
    write_markdown_table(FTL_ROOT / "tables" / "state-milestones.md", state_headers, [[r["label"]] + [format_num(r.get(h)) for h in state_headers[1:]] for r in state_m_rows])

    # Hourly checkpoints
    hourly_rows = []
    for r in runs:
        spec = r["spec"]
        rows = r["plot_rows"]
        for hour in HOURLY_MARKS:
            snap = hourly_snapshot(rows, hour)
            if snap is None:
                continue
            hourly_rows.append({
                "label": spec.label,
                "mode": spec.mode,
                "kind": spec.kind,
                "hour_mark": hour,
                "paths_total": int(snap["paths_total"]),
                "unique_hangs": int(snap["unique_hangs"]),
                "execs_per_sec": f"{snap['execs_per_sec']:.4f}",
                "n_nodes": int(snap["n_nodes"]),
                "n_edges": int(snap["n_edges"]),
                "bitmap_cvg_percent": f"{snap['map_size_pct']:.4f}",
            })
    write_csv(FTL_ROOT / "tables" / "hourly-checkpoints.csv", [sanitize_row(r) for r in hourly_rows], list(hourly_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "hourly-checkpoints.md",
        ["label", "hour_mark", "paths_total", "unique_hangs", "execs_per_sec", "n_nodes", "n_edges", "bitmap_cvg_percent"],
        [[r["label"], r["hour_mark"], r["paths_total"], r["unique_hangs"], r["execs_per_sec"], r["n_nodes"], r["n_edges"], r["bitmap_cvg_percent"]] for r in hourly_rows],
    )

    # Live 24h snapshot table
    live_rows = []
    for r in live:
        spec = r["spec"]
        plot_rows = r["plot_rows"]
        last_plot = plot_rows[-1] if plot_rows else None
        fuzzer_stats = read_fuzzer_stats(r["campaign_dir"] / "aflnet-out" / "fuzzer_stats")
        live_rows.append({
            "label": spec.label,
            "mode": spec.mode,
            "status": r["run_summary"].get("campaign_status", "in-progress"),
            "execs_done": parse_int(fuzzer_stats.get("execs_done")),
            "paths_total": parse_int(fuzzer_stats.get("paths_total")),
            "unique_hangs": parse_int(fuzzer_stats.get("unique_hangs")),
            "hours_observed": last_plot.get("hours_since_start") if last_plot else None,
            "plot_rows": len(plot_rows),
            "n_nodes_last": int(last_plot["n_nodes"]) if last_plot else None,
            "n_edges_last": int(last_plot["n_edges"]) if last_plot else None,
            "bitmap_cvg_last": last_plot.get("map_size_pct") if last_plot else None,
        })
    write_csv(FTL_ROOT / "tables" / "live-24h-interim.csv", [sanitize_row(r) for r in live_rows], list(live_rows[0].keys()))
    write_markdown_table(
        FTL_ROOT / "tables" / "live-24h-interim.md",
        ["label", "status", "execs_done", "paths_total", "unique_hangs", "hours_observed", "plot_rows", "n_nodes_last", "n_edges_last", "bitmap_cvg_last"],
        [[r["label"], r["status"], format_num(r["execs_done"]), format_num(r["paths_total"]), format_num(r["unique_hangs"]), format_num(r["hours_observed"]), format_num(r["plot_rows"]), format_num(r["n_nodes_last"]), format_num(r["n_edges_last"]), format_num(r["bitmap_cvg_last"])] for r in live_rows],
    )

    # Listings
    cmd_lines = []
    for r in completed:
        spec = r["spec"]
        cmd = (r["campaign_dir"] / "aflnet-command.txt").read_text().strip()
        cmd_lines.append(f"## {spec.label}\n\n```bash\n{cmd}\n```\n")
    (FTL_ROOT / "listings" / "aflnet-commands.md").write_text("\n".join(cmd_lines))

    cov_lines = []
    for r in completed:
        spec = r["spec"]
        c = r["comparison"]
        keys = [
            "line_covered_delta",
            "campaign_line_locations_covered",
            "line_locations_covered_by_campaign_not_baseline",
            "classes_covered_by_campaign_not_baseline",
            "packages_covered_by_campaign_not_baseline",
            "campaign_line_location_coverage_percent",
        ]
        cov_lines.append(f"## {spec.label}\n")
        for k in keys:
            cov_lines.append(f"- {k}={c.get(k, 'NA')}")
        cov_lines.append("")
    (FTL_ROOT / "listings" / "coverage-comparison-listings.md").write_text("\n".join(cov_lines))

    hang_lines = []
    for r in completed:
        spec = r["spec"]
        h = r["hang_analysis"]
        hang_lines.append(f"## {spec.label}\n")
        for k in ["replayable_hang_count", "unique_hang_hash_count", "duplicate_hang_count", "hang_size_min", "hang_size_max", "first_hang_artifact_time", "last_hang_artifact_time", "sample_hang_files"]:
            hang_lines.append(f"- {k}={h.get(k, 'NA')}")
        hang_lines.append("")
    (FTL_ROOT / "listings" / "hang-analysis-listings.md").write_text("\n".join(hang_lines))

    line_sample_sections = []
    for r in completed:
        spec = r["spec"]
        sample = sample_lines(r["line_details"] / "campaign-only-covered-lines.txt", 15)
        line_sample_sections.append(f"## {spec.label}\n\nTop sample lines from campaign-only-covered-lines.txt\n\n```text\n" + "\n".join(sample) + "\n```\n")
    (FTL_ROOT / "listings" / "line-detail-samples.md").write_text("\n".join(line_sample_sections))

    report_sections = []
    for r in completed:
        spec = r["spec"]
        report = r["campaign_dir"] / "campaign-report.md"
        excerpt = sample_lines(report, 80)
        report_sections.append(f"## {spec.label}\n\n```markdown\n" + "\n".join(excerpt) + "\n```\n")
    (FTL_ROOT / "listings" / "campaign-report-excerpts.md").write_text("\n".join(report_sections))

    # Figures (completed matrix)
    completed_series_paths = [(r["spec"].label, r["spec"].color, [(row["hours_since_start"], row["paths_total"]) for row in r["plot_rows"]]) for r in completed]
    completed_series_hangs = [(r["spec"].label, r["spec"].color, [(row["hours_since_start"], row["unique_hangs"]) for row in r["plot_rows"]]) for r in completed]
    completed_series_eps = [(r["spec"].label, r["spec"].color, [(row["hours_since_start"], row["execs_per_sec"]) for row in r["plot_rows"]]) for r in completed]
    completed_series_nodes = [(r["spec"].label, r["spec"].color, [(row["hours_since_start"], row["n_nodes"]) for row in r["plot_rows"]]) for r in completed]
    completed_series_edges = [(r["spec"].label, r["spec"].color, [(row["hours_since_start"], row["n_edges"]) for row in r["plot_rows"]]) for r in completed]
    completed_series_bitmap = [(r["spec"].label, r["spec"].color, [(row["hours_since_start"], row["map_size_pct"]) for row in r["plot_rows"]]) for r in completed]
    completed_series_norm_paths = []
    for r in completed:
        pts = []
        final_paths = r["plot_rows"][-1]["paths_total"] if r["plot_rows"] else 1.0
        for row in r["plot_rows"]:
            pts.append((row["hours_since_start"], 100.0 * row["paths_total"] / final_paths if final_paths else 0.0))
        completed_series_norm_paths.append((r["spec"].label, r["spec"].color, pts))

    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-paths-total-vs-hours.svg", "Completed 12h campaigns: paths_total vs hours", completed_series_paths, "paths_total")
    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-unique-hangs-vs-hours.svg", "Completed 12h campaigns: unique_hangs vs hours", completed_series_hangs, "unique_hangs")
    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-execs-per-sec-vs-hours.svg", "Completed 12h campaigns: execs_per_sec vs hours", completed_series_eps, "execs_per_sec")
    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-state-nodes-vs-hours.svg", "Completed 12h campaigns: state nodes vs hours", completed_series_nodes, "n_nodes")
    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-state-edges-vs-hours.svg", "Completed 12h campaigns: state edges vs hours", completed_series_edges, "n_edges")
    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-bitmap-cvg-vs-hours.svg", "Completed 12h campaigns: bitmap coverage % vs hours", completed_series_bitmap, "bitmap coverage %")
    make_svg_line_chart(FTL_ROOT / "figures" / "completed-12h-normalized-path-progress.svg", "Completed 12h campaigns: normalized path progress", completed_series_norm_paths, "% of final paths_total")

    make_svg_bar_chart(FTL_ROOT / "figures" / "completed-12h-final-paths-bar.svg", "Completed 12h campaigns: final queue_paths_found", [(r["spec"].label, r["spec"].color, parse_float(r["run_summary"].get("queue_paths_found")) or 0.0) for r in completed], "queue_paths_found")
    make_svg_bar_chart(FTL_ROOT / "figures" / "completed-12h-final-execs-bar.svg", "Completed 12h campaigns: execs_done", [(r["spec"].label, r["spec"].color, parse_float(r["run_summary"].get("execs_done")) or 0.0) for r in completed], "execs_done")
    make_svg_bar_chart(FTL_ROOT / "figures" / "completed-12h-final-hangs-bar.svg", "Completed 12h campaigns: replayable_hangs", [(r["spec"].label, r["spec"].color, parse_float(r["run_summary"].get("replayable_hangs")) or 0.0) for r in completed], "replayable_hangs")
    make_svg_bar_chart(FTL_ROOT / "figures" / "completed-12h-jacoco-line-delta-bar.svg", "Completed 12h campaigns: JaCoCo line_covered_delta", [(r["spec"].label, r["spec"].color, parse_float(r["comparison"].get("line_covered_delta")) or 0.0) for r in completed], "line_covered_delta")
    make_svg_scatter(FTL_ROOT / "figures" / "completed-12h-queue-vs-execs-scatter.svg", "Completed 12h campaigns: queue_paths_found vs execs_done", [(r["spec"].label, r["spec"].color, parse_float(r["run_summary"].get("execs_done")) or 0.0, parse_float(r["run_summary"].get("queue_paths_found")) or 0.0) for r in completed], "execs_done", "queue_paths_found")

    # Live 24h figures
    for r in live:
        pts_paths = [(row["hours_since_start"], row["paths_total"]) for row in r["plot_rows"]]
        pts_hangs = [(row["hours_since_start"], row["unique_hangs"]) for row in r["plot_rows"]]
        pts_nodes = [(row["hours_since_start"], row["n_nodes"]) for row in r["plot_rows"]]
        pts_edges = [(row["hours_since_start"], row["n_edges"]) for row in r["plot_rows"]]
        make_svg_line_chart(FTL_ROOT / "figures" / "live-24h-paths-total-vs-hours.svg", "24h state+coverage: paths_total vs hours", [(r["spec"].label, r["spec"].color, pts_paths)], "paths_total")
        make_svg_line_chart(FTL_ROOT / "figures" / "live-24h-unique-hangs-vs-hours.svg", "24h state+coverage: unique_hangs vs hours", [(r["spec"].label, r["spec"].color, pts_hangs)], "unique_hangs")
        make_svg_line_chart(FTL_ROOT / "figures" / "live-24h-state-nodes-vs-hours.svg", "24h state+coverage: n_nodes vs hours", [(r["spec"].label, r["spec"].color, pts_nodes)], "n_nodes")
        make_svg_line_chart(FTL_ROOT / "figures" / "live-24h-state-edges-vs-hours.svg", "24h state+coverage: n_edges vs hours", [(r["spec"].label, r["spec"].color, pts_edges)], "n_edges")

    # README / index
    index = [
        "# FTL Artifact Index",
        "",
        "Generated comparison bundle for the completed 12h matrix runs plus the completed clean 24h state+coverage run.",
        "",
        "## Caveats",
        "",
        "- `unique_hangs=500` is an AFLNet retention cap (`KEEP_UNIQUE_HANG`), not proof the target maxed out at 500.",
        "- JaCoCo campaign coverage is whole-process coverage, not AFLNet feedback.",
        "- The `24h state+coverage` artifacts use the clean completed local-staging rerun (`20260505T045009Z-state-aware-86400s`).",
        "",
        "## Tables",
        "",
        "- `tables/run-manifest.md` / `.csv` — run inventory and paths.",
        "- `tables/final-matrix-summary.md` / `.csv` — end-state comparison table for the completed 12h matrix.",
        "- `tables/normalized-comparison.md` / `.csv` — per-hour and per-10k-exec normalized rates.",
        "- `tables/feedback-state-edge.md` / `.csv` — feedback mode, state growth, edge metrics, bitmap metrics.",
        "- `tables/jacoco-comparison.md` / `.csv` — JaCoCo XML aggregate comparison metrics.",
        "- `tables/target-diagnostics.md` / `.csv` — target-side diagnostic counts and classifications.",
        "- `tables/hang-analysis.md` / `.csv` — retained-hang artifact summary, duplicate counts, cap note.",
        "- `tables/line-detail-counts.md` / `.csv` — counts for line-detail listing files.",
        "- `tables/path-milestones.md` / `.csv` — time-to-path-count milestones.",
        "- `tables/hang-milestones.md` / `.csv` — time-to-hang-count milestones.",
        "- `tables/state-milestones.md` / `.csv` — time-to-state-node/edge milestones.",
        "- `tables/hourly-checkpoints.md` / `.csv` — hour-by-hour snapshots across campaigns.",
        "- `tables/live-24h-interim.md` / `.csv` — final status of the completed 24h run; filename retained for compatibility with earlier drafts.",
        "",
        "## Figures",
        "",
        "- `figures/completed-12h-paths-total-vs-hours.svg`",
        "- `figures/completed-12h-unique-hangs-vs-hours.svg`",
        "- `figures/completed-12h-execs-per-sec-vs-hours.svg`",
        "- `figures/completed-12h-state-nodes-vs-hours.svg`",
        "- `figures/completed-12h-state-edges-vs-hours.svg`",
        "- `figures/completed-12h-bitmap-cvg-vs-hours.svg`",
        "- `figures/completed-12h-normalized-path-progress.svg`",
        "- `figures/completed-12h-final-paths-bar.svg`",
        "- `figures/completed-12h-final-execs-bar.svg`",
        "- `figures/completed-12h-final-hangs-bar.svg`",
        "- `figures/completed-12h-jacoco-line-delta-bar.svg`",
        "- `figures/completed-12h-queue-vs-execs-scatter.svg`",
        "- `figures/live-24h-paths-total-vs-hours.svg`",
        "- `figures/live-24h-unique-hangs-vs-hours.svg`",
        "- `figures/live-24h-state-nodes-vs-hours.svg`",
        "- `figures/live-24h-state-edges-vs-hours.svg`",
        "",
        "## Listings",
        "",
        "- `listings/aflnet-commands.md` — exact AFLNet command lines per mode.",
        "- `listings/coverage-comparison-listings.md` — key coverage-comparison key/value excerpts.",
        "- `listings/hang-analysis-listings.md` — key hang-analysis key/value excerpts.",
        "- `listings/line-detail-samples.md` — sampled campaign-only covered lines per mode.",
        "- `listings/campaign-report-excerpts.md` — first ~80 lines from each campaign report.",
        "",
        "## Data",
        "",
        "- `data/<run-slug>-timeseries.csv` — dense timeseries exports derived from `plot_data` for each run.",
    ]
    (FTL_ROOT / "README.md").write_text("\n".join(index) + "\n")


if __name__ == "__main__":
    main()
