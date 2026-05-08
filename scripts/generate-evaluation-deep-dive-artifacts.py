#!/usr/bin/env python3
from __future__ import annotations

import csv
import hashlib
import math
import os
import random
import re
import shutil
import statistics
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent.parent
EVAL_ROOT = Path(os.environ.get("DEEP_DIVE_EVAL_ROOT", ROOT / "eval-runs"))
OUT_ROOT = Path(os.environ.get("DEEP_DIVE_OUTPUT_ROOT", ROOT / "FTL" / "investigations" / "evaluation-artifact-deep-dive"))
TABLES = OUT_ROOT / "tables"
FIGURES = OUT_ROOT / "figures"
LISTINGS = OUT_ROOT / "listings"
DATA = OUT_ROOT / "data"
REPLAY_LOGS = OUT_ROOT / "replay-logs"


@dataclass(frozen=True)
class RunSpec:
    slug: str
    label: str
    short_label: str
    mode: str
    color: str
    kind: str
    primary: bool = True
    clean: bool = True


RUNS = [
    RunSpec("20260503T054121Z-state-aware-43200s", "12h state+coverage", "12h-sc", "state-aware", "#1f77b4", "matrix12h"),
    RunSpec("20260503T054505Z-code-only-43200s", "12h coverage-only", "12h-c", "code-only", "#ff7f0e", "matrix12h"),
    RunSpec("20260503T054506Z-state-only-43200s", "12h state-only", "12h-s", "state-only", "#2ca02c", "matrix12h"),
    RunSpec("20260505T045009Z-state-aware-86400s", "24h state+coverage (completed PASS)", "24h-sc", "state-aware", "#9467bd", "matrix24h"),
    RunSpec("20260507T071141Z-state-aware-39600s", "11h state+coverage (campaign-epoch)", "11h-sc-epoch", "state-aware", "#d62728", "followup11h"),
    RunSpec("20260503T045624Z-state-aware-86400s", "24h state+coverage (recovered wrapper-failed)", "24h-sc-recovered", "state-aware", "#8c564b", "recovered24h", primary=False, clean=False),
]

PRIMARY_RUNS = [r for r in RUNS if r.primary]
STATE_RUNS = [r for r in RUNS if r.mode in ("state-aware", "state-only")]

QUEUE_NAME_RE = re.compile(r"^id:(?P<id>\d+)(?:,orig:(?P<orig>.+)|,src:(?P<src>[^,]+),op:(?P<op>[^,]+),rep:(?P<rep>\d+)(?P<cov>,\+cov)?)$")
NODE_RE = re.compile(r"^\s*(?P<node>\d+)\s*\[color=(?P<color>[^\]]+)\];")
EDGE_RE = re.compile(r"^\s*(?P<src>\d+)\s*->\s*(?P<dst>\d+)")
LOG_TIME_RE = re.compile(r"^\[(?P<h>\d{2}):(?P<m>\d{2}):(?P<s>\d{2})\s+(?P<level>[A-Z]+)\]:\s*(?P<msg>.*)$")
LOG_RFC3339_RE = re.compile(r"^(?P<iso>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+\S+\s+(?P<level>[A-Z]+)\s+(?P<msg>.*)$")
EXC_LINE_RE = re.compile(r"^(?P<cls>[A-Za-z0-9_.$]+(?:Exception|Error))(?:\:\s*(?P<msg>.*))?$")
STACK_RE = re.compile(r"^\s+at\s+(?P<frame>[^\s(]+)")

TARGET_CLASS_PATTERNS = {
    "connection_reset": re.compile(r"ECONNRESET|connection reset|Connection reset", re.I),
    "timeout": re.compile(r"timeout|timed out", re.I),
    "backend_or_session": re.compile(r"\[server connection\].*exception encountered|ClassCastException|internal server connection error|Unable to connect to lobby|backend", re.I),
    "handled_client": re.compile(r"\[initial connection\].*provided invalid protocol|\[connected player\].*(disconnected while connecting|has disconnected)|malformed|bad packet", re.I),
}


@dataclass
class QueueEntry:
    run_slug: str
    path: Path
    id_num: int
    orig: str | None
    src_ids: list[int]
    op: str | None
    rep: int | None
    cov: bool
    size: int
    mtime: float
    hours_since_start: float | None


@dataclass
class StateMachine:
    nodes: dict[int, str]
    edges: set[tuple[int, int]]


@dataclass
class ExceptionEvent:
    run_slug: str
    hour_bucket: int
    rel_hours: float
    exc_class: str
    top_frame: str
    message_norm: str
    context_kind: str
    context_line: str
    raw_line: str
    line_no: int


@dataclass
class RunArtifacts:
    spec: RunSpec
    root: Path
    campaign_dir: Path
    queue_dir: Path
    replayable_hangs_dir: Path
    state_path_dir: Path
    fuzzer_stats: dict[str, str]
    run_summary: dict[str, str]
    eval_summary: dict[str, str]
    comparison: dict[str, str]
    hang_analysis: dict[str, str]
    plot_rows: list[dict[str, float]]
    start_time: float | None
    queue_entries: list[QueueEntry]
    hang_entries: list[QueueEntry]
    state_machine: StateMachine | None


def ensure_dirs() -> None:
    for path in [OUT_ROOT, TABLES, FIGURES, LISTINGS, DATA, REPLAY_LOGS]:
        path.mkdir(parents=True, exist_ok=True)


def read_text(path: Path) -> str:
    return path.read_text(errors="replace") if path.exists() else ""


def read_kv_equals(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def read_fuzzer_stats(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(errors="replace").splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        data[k.strip()] = v.strip()
    return data


def parse_int(value: str | None) -> int | None:
    if value in (None, "", "unavailable", "NA"):
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def parse_float(value: str | None) -> float | None:
    if value in (None, "", "unavailable", "NA"):
        return None
    try:
        return float(str(value).rstrip("%"))
    except ValueError:
        return None


def iso(ts: float | int | None) -> str:
    if ts is None:
        return "unavailable"
    return datetime.fromtimestamp(float(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slugify(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")


def format_num(value: object) -> str:
    if value is None:
        return "NA"
    if isinstance(value, float):
        if math.isnan(value):
            return "NA"
        if value.is_integer():
            return str(int(value))
        return f"{value:.2f}"
    return str(value)


def write_csv(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def write_markdown_table(path: Path, headers: list[str], rows: list[list[object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        f.write("| " + " | ".join(headers) + " |\n")
        f.write("| " + " | ".join(["---"] * len(headers)) + " |\n")
        for row in rows:
            f.write("| " + " | ".join(format_num(x) for x in row) + " |\n")


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
            row = {
                "unix_time": float(parts[0]),
                "cycles_done": float(parts[1]),
                "cur_path": float(parts[2]),
                "paths_total": float(parts[3]),
                "pending_total": float(parts[4]),
                "pending_favs": float(parts[5]),
                "map_size_pct": float(parts[6].rstrip("%")),
                "unique_crashes": float(parts[7]),
                "unique_hangs": float(parts[8]),
                "max_depth": float(parts[9]),
                "execs_per_sec": float(parts[10]),
                "n_nodes": float(parts[11]),
                "n_edges": float(parts[12]),
            }
            rows.append(row)
    if rows:
        start = rows[0]["unix_time"]
        for row in rows:
            row["hours_since_start"] = (row["unix_time"] - start) / 3600.0
    return rows


def parse_queue_filename(name: str) -> tuple[int, str | None, list[int], str | None, int | None, bool]:
    m = QUEUE_NAME_RE.match(name)
    if not m:
        raise ValueError(f"Unrecognized queue filename: {name}")
    id_num = int(m.group("id"))
    orig = m.group("orig")
    src_raw = m.group("src")
    src_ids = [int(part) for part in src_raw.split("+") if part] if src_raw else []
    op = m.group("op")
    rep = int(m.group("rep")) if m.group("rep") else None
    cov = bool(m.group("cov"))
    return id_num, orig, src_ids, op, rep, cov


def load_queue_entries(run_slug: str, directory: Path, start_time: float | None) -> list[QueueEntry]:
    entries: list[QueueEntry] = []
    if not directory.exists():
        return entries
    for path in sorted([p for p in directory.iterdir() if p.is_file()], key=lambda p: p.name):
        try:
            id_num, orig, src_ids, op, rep, cov = parse_queue_filename(path.name)
        except ValueError:
            continue
        st = path.stat()
        hours_since_start = (st.st_mtime - start_time) / 3600.0 if start_time else None
        entries.append(QueueEntry(run_slug, path, id_num, orig, src_ids, op, rep, cov, st.st_size, st.st_mtime, hours_since_start))
    return entries


def parse_state_machine(path: Path) -> StateMachine | None:
    if not path.exists():
        return None
    nodes: dict[int, str] = {}
    edges: set[tuple[int, int]] = set()
    for line in path.read_text(errors="replace").splitlines():
        m = NODE_RE.match(line)
        if m:
            nodes[int(m.group("node"))] = m.group("color")
            continue
        m = EDGE_RE.match(line)
        if m:
            edges.add((int(m.group("src")), int(m.group("dst"))))
    return StateMachine(nodes, edges)


def load_run(spec: RunSpec) -> RunArtifacts:
    root = EVAL_ROOT / spec.slug
    campaign = root / "campaign"
    run_summary = read_kv_equals(campaign / "run-summary.txt")
    eval_summary = read_kv_equals(root / "eval-summary.txt")
    comparison = read_kv_equals(campaign / "coverage" / "comparison-vs-latest-baseline.txt")
    hang_analysis = read_kv_equals(campaign / "hang-analysis.txt")
    fuzzer_stats = read_fuzzer_stats(campaign / "aflnet-out" / "fuzzer_stats")
    plot_rows = read_plot_data(campaign / "aflnet-out" / "plot_data")
    start_time = parse_float(fuzzer_stats.get("start_time"))
    queue_dir = campaign / "aflnet-out" / "queue"
    replayable_hangs_dir = campaign / "aflnet-out" / "replayable-hangs"
    state_path_dir = campaign / "aflnet-out" / "replayable-new-ipsm-paths"
    queue_entries = load_queue_entries(spec.slug, queue_dir, start_time)
    hang_entries = load_queue_entries(spec.slug, replayable_hangs_dir, start_time)
    state_machine = parse_state_machine(campaign / "aflnet-out" / "ipsm.dot")
    return RunArtifacts(
        spec=spec,
        root=root,
        campaign_dir=campaign,
        queue_dir=queue_dir,
        replayable_hangs_dir=replayable_hangs_dir,
        state_path_dir=state_path_dir,
        fuzzer_stats=fuzzer_stats,
        run_summary=run_summary,
        eval_summary=eval_summary,
        comparison=comparison,
        hang_analysis=hang_analysis,
        plot_rows=plot_rows,
        start_time=start_time,
        queue_entries=queue_entries,
        hang_entries=hang_entries,
        state_machine=state_machine,
    )


def pick_interesting_queue_entries(run: RunArtifacts) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    entries = run.queue_entries
    if not entries:
        return rows
    seen: set[Path] = set()
    groups = [
        ("smallest", sorted(entries, key=lambda e: (e.size, e.id_num))[:5]),
        ("largest", sorted(entries, key=lambda e: (-e.size, e.id_num))[:5]),
        ("latest", sorted(entries, key=lambda e: (e.mtime, e.id_num))[-10:]),
    ]
    if run.spec.slug == "20260505T045009Z-state-aware-86400s":
        late = [e for e in entries if (e.hours_since_start or 0) >= 12.0]
        groups.append(("24h_late_after_12h", sorted(late, key=lambda e: (e.mtime, e.id_num))[:15]))
    for group, items in groups:
        for e in items:
            if (group != "24h_late_after_12h") and e.path in seen:
                continue
            seen.add(e.path)
            rows.append({
                "label": run.spec.label,
                "group": group,
                "id": e.id_num,
                "filename": e.path.name,
                "size": e.size,
                "hours_since_start": e.hours_since_start,
                "orig": e.orig or "",
                "src_ids": "+".join(str(x) for x in e.src_ids),
                "op": e.op or "orig",
                "rep": e.rep,
                "cov": "yes" if e.cov else "no",
                "path": str(e.path),
            })
    return rows


def queue_mutation_summary(run: RunArtifacts) -> list[dict[str, object]]:
    counter = Counter((e.op or "orig") for e in run.queue_entries)
    return [{"label": run.spec.label, "op": op, "count": count} for op, count in sorted(counter.items())]


def productive_ancestors(entries: list[QueueEntry]) -> Counter[int]:
    counter: Counter[int] = Counter()
    for e in entries:
        for src in e.src_ids:
            counter[src] += 1
    return counter


def late_entries(entries: list[QueueEntry], hour_cutoff: float) -> list[QueueEntry]:
    return [e for e in entries if e.hours_since_start is not None and e.hours_since_start >= hour_cutoff]


def plot_time_for_paths(rows: list[dict[str, float]], target: int) -> float | None:
    for row in rows:
        if int(row["paths_total"]) >= target:
            return row["hours_since_start"]
    return None


def plot_time_for_metric(rows: list[dict[str, float]], key: str, target: int) -> float | None:
    for row in rows:
        if int(row[key]) >= target:
            return row["hours_since_start"]
    return None


def state_machine_summary(run: RunArtifacts) -> dict[str, object]:
    keys = {
        "label": run.spec.label,
        "nodes": 0,
        "edges": 0,
        "self_loops": 0,
        "max_in_degree": 0,
        "max_out_degree": 0,
        "blue_nodes": 0,
        "red_nodes": 0,
    }
    sm = run.state_machine
    if not sm:
        return keys
    indeg = Counter(dst for _, dst in sm.edges)
    outdeg = Counter(src for src, _ in sm.edges)
    self_loops = sum(1 for src, dst in sm.edges if src == dst)
    keys.update({
        "nodes": len(sm.nodes),
        "edges": len(sm.edges),
        "self_loops": self_loops,
        "max_in_degree": max(indeg.values(), default=0),
        "max_out_degree": max(outdeg.values(), default=0),
        "blue_nodes": sum(1 for c in sm.nodes.values() if "blue" in c),
        "red_nodes": sum(1 for c in sm.nodes.values() if "red" in c),
    })
    return keys


def state_degree_rows(run: RunArtifacts) -> list[dict[str, object]]:
    sm = run.state_machine
    if not sm:
        return []
    indeg = Counter(dst for _, dst in sm.edges)
    outdeg = Counter(src for src, _ in sm.edges)
    rows = []
    for node in sorted(sm.nodes):
        rows.append({
            "label": run.spec.label,
            "node": node,
            "color": sm.nodes.get(node, "unknown"),
            "in_degree": indeg.get(node, 0),
            "out_degree": outdeg.get(node, 0),
            "self_loop": "yes" if (node, node) in sm.edges else "no",
        })
    rows.sort(key=lambda r: (-int(r["out_degree"]), -int(r["in_degree"]), int(r["node"])))
    return rows


def make_diff_state_machine(a: RunArtifacts, b: RunArtifacts, dot_path: Path) -> None:
    if not a.state_machine or not b.state_machine:
        return
    sm_a = a.state_machine
    sm_b = b.state_machine
    nodes = sorted(set(sm_a.nodes) | set(sm_b.nodes))
    edges_a = sm_a.edges
    edges_b = sm_b.edges
    lines = ["digraph g {", "  rankdir=LR;", "  node [shape=circle, style=filled, fillcolor=white, color=black];"]
    for node in nodes:
        lines.append(f"  {node};")
    for src, dst in sorted(edges_a | edges_b):
        if (src, dst) in edges_a and (src, dst) in edges_b:
            color = "gray40"
            penwidth = 2
        elif (src, dst) in edges_a:
            color = "blue"
            penwidth = 2
        else:
            color = "orange"
            penwidth = 2
        lines.append(f"  {src} -> {dst} [color={color}, penwidth={penwidth}];")
    lines.append("}")
    dot_path.write_text("\n".join(lines) + "\n")


def render_dot(dot_path: Path, svg_path: Path) -> None:
    if shutil.which("dot") is None or not dot_path.exists():
        return
    subprocess.run(["dot", "-Tsvg", str(dot_path), "-o", str(svg_path)], check=False)


def normalize_message(msg: str) -> str:
    out = msg
    out = re.sub(r"/\d+\.\d+\.\d+\.\d+:\d+", "/<ip:port>", out)
    out = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}:\d+\b", "<ip:port>", out)
    out = re.sub(r"@[0-9a-fA-F]+", "@<hex>", out)
    out = re.sub(r"\b0x[0-9a-fA-F]+\b", "<hex>", out)
    out = re.sub(r"\b\d{5,}\b", "<n>", out)
    out = re.sub(r"\s+", " ", out).strip()
    return out


def parse_log_events(path: Path) -> list[tuple[float, str, str]]:
    events: list[tuple[float, str, str]] = []
    if not path.exists():
        return events
    offset = 0
    last_secs: int | None = None
    for line in path.read_text(errors="replace").splitlines():
        m = LOG_TIME_RE.match(line)
        if m:
            secs = int(m.group("h")) * 3600 + int(m.group("m")) * 60 + int(m.group("s"))
            if last_secs is not None and secs < last_secs:
                offset += 86400
            last_secs = secs
            events.append((offset + secs, m.group("level"), m.group("msg")))
            continue
        m = LOG_RFC3339_RE.match(line)
        if m:
            try:
                ts = datetime.fromisoformat(m.group("iso").replace("Z", "+00:00")).timestamp()
            except ValueError:
                ts = 0.0
            if events:
                base = events[0][0]
                rel = max(0.0, ts - ts)
                events.append((rel, m.group("level"), m.group("msg")))
            else:
                events.append((0.0, m.group("level"), m.group("msg")))
            continue
    return events


def classify_context(msg: str) -> str:
    lowered = msg.lower()
    if "server connection" in lowered:
        return "server-connection"
    if "connected player" in lowered:
        return "connected-player"
    if "initial connection" in lowered:
        return "initial-connection"
    return "other"


def extract_exception_events(run: RunArtifacts) -> list[ExceptionEvent]:
    lines = read_text(run.campaign_dir / "logs" / "velocity.log").splitlines()
    events: list[ExceptionEvent] = []
    offset = 0
    last_secs: int | None = None
    current_time = 0.0
    for idx, line in enumerate(lines):
        m = LOG_TIME_RE.match(line)
        if m:
            secs = int(m.group("h")) * 3600 + int(m.group("m")) * 60 + int(m.group("s"))
            if last_secs is not None and secs < last_secs:
                offset += 86400
            last_secs = secs
            current_time = offset + secs
        elif LOG_RFC3339_RE.match(line):
            current_time = 0.0

        if "ERROR" not in line and "WARN" not in line:
            continue
        if "exception encountered" not in line and "Exception" not in line and "Error" not in line:
            continue

        exc_class = None
        exc_message = ""
        top_frame = ""
        raw_exc = ""
        for look_ahead in range(1, 8):
            if idx + look_ahead >= len(lines):
                break
            nxt = lines[idx + look_ahead].rstrip()
            m_exc = EXC_LINE_RE.match(nxt)
            if m_exc:
                exc_class = m_exc.group("cls")
                exc_message = normalize_message(m_exc.group("msg") or "")
                raw_exc = nxt
                for frame_ahead in range(look_ahead + 1, min(look_ahead + 8, len(lines) - idx)):
                    frame_line = lines[idx + frame_ahead]
                    m_frame = STACK_RE.match(frame_line)
                    if m_frame:
                        top_frame = m_frame.group("frame")
                        break
                break
        if not exc_class:
            continue
        rel_hours = current_time / 3600.0
        events.append(ExceptionEvent(
            run.spec.slug,
            int(rel_hours),
            rel_hours,
            exc_class,
            top_frame or "<no-frame>",
            exc_message or "<no-message>",
            classify_context(line),
            line.strip(),
            raw_exc or line.strip(),
            idx + 1,
        ))
    return events


def hang_artifact_hash_rows(run: RunArtifacts) -> list[dict[str, object]]:
    rows = []
    by_hash: dict[str, list[QueueEntry]] = defaultdict(list)
    for entry in run.hang_entries:
        digest = hashlib.sha256(entry.path.read_bytes()).hexdigest()
        by_hash[digest].append(entry)
    for digest, items in sorted(by_hash.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        if len(items) <= 1:
            continue
        rows.append({
            "label": run.spec.label,
            "sha256": digest,
            "count": len(items),
            "sample_files": ",".join(e.path.name for e in items[:5]),
            "size_min": min(e.size for e in items),
            "size_max": max(e.size for e in items),
        })
    return rows


def choose_hang_candidates(run: RunArtifacts) -> list[dict[str, object]]:
    entries = run.hang_entries
    if not entries:
        return []
    random.seed(0)
    by_hash: dict[str, list[QueueEntry]] = defaultdict(list)
    for entry in entries:
        by_hash[hashlib.sha256(entry.path.read_bytes()).hexdigest()].append(entry)
    groups: list[tuple[str, list[QueueEntry]]] = [
        ("first", sorted(entries, key=lambda e: (e.mtime, e.id_num))[:5]),
        ("last", sorted(entries, key=lambda e: (e.mtime, e.id_num))[-5:]),
        ("largest", sorted(entries, key=lambda e: (-e.size, e.id_num))[:5]),
        ("smallest", sorted(entries, key=lambda e: (e.size, e.id_num))[:5]),
        ("duplicate-hash-representative", [items[0] for items in by_hash.values() if len(items) > 1][:5]),
    ]
    # random stratified by timeline quartiles
    entries_by_time = sorted(entries, key=lambda e: (e.mtime, e.id_num))
    quart = max(1, len(entries_by_time) // 4)
    stratified = []
    for i in range(0, len(entries_by_time), quart):
        bucket = entries_by_time[i:i+quart]
        if bucket:
            stratified.append(random.choice(bucket))
    groups.append(("random-stratified", stratified[:8]))

    rows = []
    seen: set[tuple[str, str]] = set()
    for group, items in groups:
        for entry in items:
            key = (group, entry.path.name)
            if key in seen:
                continue
            seen.add(key)
            rows.append({
                "label": run.spec.label,
                "group": group,
                "filename": entry.path.name,
                "size": entry.size,
                "hours_since_start": entry.hours_since_start,
                "src_ids": "+".join(str(x) for x in entry.src_ids),
                "op": entry.op or "orig",
                "rep": entry.rep,
                "sha256": hashlib.sha256(entry.path.read_bytes()).hexdigest(),
                "path": str(entry.path),
            })
    return rows


def read_line_set(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()}


def read_targeted_replay(dir_path: Path) -> tuple[dict[str, str], list[dict[str, str]]]:
    summary = read_kv_equals(dir_path / "hang-replay-classification.txt")
    manifest: dict[str, str] = {}
    selected = dir_path / "selected-candidates.txt"
    if selected.exists():
        for line in selected.read_text(errors="replace").splitlines():
            if not line.strip() or "," not in line:
                continue
            group, path = line.split(",", 1)
            manifest[Path(path).name] = group
    sample_rows: list[dict[str, str]] = []
    sample_count = parse_int(summary.get("replay_sample_count")) or 0
    for idx in range(1, sample_count + 1):
        filename = summary.get(f"sample_{idx}_file", "")
        raw_log = summary.get(f"sample_{idx}_log", "")
        sample_rows.append({
            "sample_index": str(idx),
            "group": manifest.get(filename, "unknown"),
            "filename": filename,
            "exit": summary.get(f"sample_{idx}_exit", ""),
            "class": summary.get(f"sample_{idx}_class", ""),
            "duration_seconds": summary.get(f"sample_{idx}_duration_seconds", ""),
            "packet_count": summary.get(f"sample_{idx}_packet_count", ""),
            "response_sequence": summary.get(f"sample_{idx}_response_sequence", ""),
            "log": f"hang-replay-logs/{Path(raw_log).name}" if raw_log else "",
        })
    return summary, sample_rows


def package_of(line_loc: str) -> str:
    parts = line_loc.split(":", 1)[0].split("/")[:-1]
    return "/".join(parts)


def class_of(line_loc: str) -> str:
    return line_loc.split(":", 1)[0]


def svg_header(width: int, height: int) -> list[str]:
    return [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">', '<rect width="100%" height="100%" fill="white"/>']


def escape_xml(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def write_svg(path: Path, lines: Iterable[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def make_multi_line_chart(path: Path, title: str, series: list[tuple[str, str, list[tuple[float, float]]]], y_label: str) -> None:
    width, height = 900, 420
    margin_left, margin_right, margin_top, margin_bottom = 70, 20, 40, 45
    all_points = [pt for _, _, pts in series for pt in pts]
    if not all_points:
        return
    max_x = max(x for x, _ in all_points) or 1.0
    max_y = max(y for _, y in all_points) or 1.0
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom

    def xpx(x: float) -> float:
        return margin_left + plot_w * (x / max_x)

    def ypx(y: float) -> float:
        return margin_top + plot_h * (1 - (y / max_y if max_y else 0))

    lines = svg_header(width, height)
    lines.append(f'<text x="{width/2}" y="22" text-anchor="middle" font-size="18">{escape_xml(title)}</text>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top+plot_h}" x2="{margin_left+plot_w}" y2="{margin_top+plot_h}" stroke="black"/>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{margin_top+plot_h}" stroke="black"/>')
    for i in range(6):
        y = max_y * i / 5.0
        py = ypx(y)
        lines.append(f'<line x1="{margin_left}" y1="{py:.2f}" x2="{margin_left+plot_w}" y2="{py:.2f}" stroke="#dddddd"/>')
        lines.append(f'<text x="{margin_left-8}" y="{py+4:.2f}" text-anchor="end" font-size="11">{y:.0f}</text>')
    for i in range(6):
        x = max_x * i / 5.0
        px = xpx(x)
        lines.append(f'<line x1="{px:.2f}" y1="{margin_top}" x2="{px:.2f}" y2="{margin_top+plot_h}" stroke="#eeeeee"/>')
        lines.append(f'<text x="{px:.2f}" y="{margin_top+plot_h+18}" text-anchor="middle" font-size="11">{x:.1f}</text>')
    legend_y = margin_top + 12
    legend_x = width - margin_right - 240
    for i, (label, color, pts) in enumerate(series):
        if len(pts) >= 2:
            poly = " ".join(f"{xpx(x):.2f},{ypx(y):.2f}" for x, y in pts)
            lines.append(f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{poly}"/>')
        elif pts:
            x, y = pts[0]
            lines.append(f'<circle cx="{xpx(x):.2f}" cy="{ypx(y):.2f}" r="3" fill="{color}"/>')
        ly = legend_y + i * 16
        lines.append(f'<line x1="{legend_x}" y1="{ly}" x2="{legend_x+16}" y2="{ly}" stroke="{color}" stroke-width="2"/>')
        lines.append(f'<text x="{legend_x+22}" y="{ly+4}" font-size="12">{escape_xml(label)}</text>')
    lines.append(f'<text x="{width/2}" y="{height-8}" text-anchor="middle" font-size="12">hours since start</text>')
    lines.append(f'<text x="16" y="{height/2}" transform="rotate(-90 16 {height/2})" text-anchor="middle" font-size="12">{escape_xml(y_label)}</text>')
    lines.append('</svg>')
    write_svg(path, lines)


def make_scatter_chart(path: Path, title: str, series: list[tuple[str, str, list[tuple[float, float]]]], y_label: str) -> None:
    width, height = 900, 420
    margin_left, margin_right, margin_top, margin_bottom = 70, 20, 40, 45
    all_points = [pt for _, _, pts in series for pt in pts]
    if not all_points:
        return
    max_x = max(x for x, _ in all_points) or 1.0
    max_y = max(y for _, y in all_points) or 1.0
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom

    def xpx(x: float) -> float:
        return margin_left + plot_w * (x / max_x)

    def ypx(y: float) -> float:
        return margin_top + plot_h * (1 - (y / max_y if max_y else 0))

    lines = svg_header(width, height)
    lines.append(f'<text x="{width/2}" y="22" text-anchor="middle" font-size="18">{escape_xml(title)}</text>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top+plot_h}" x2="{margin_left+plot_w}" y2="{margin_top+plot_h}" stroke="black"/>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{margin_top+plot_h}" stroke="black"/>')
    for label, color, pts in series:
        for x, y in pts:
            lines.append(f'<circle cx="{xpx(x):.2f}" cy="{ypx(y):.2f}" r="2.5" fill="{color}" opacity="0.75"/>')
    lines.append(f'<text x="{width/2}" y="{height-8}" text-anchor="middle" font-size="12">x</text>')
    lines.append(f'<text x="16" y="{height/2}" transform="rotate(-90 16 {height/2})" text-anchor="middle" font-size="12">{escape_xml(y_label)}</text>')
    lines.append('</svg>')
    write_svg(path, lines)


def make_bar_chart(path: Path, title: str, values: list[tuple[str, str, float]], y_label: str) -> None:
    width, height = 960, 420
    margin_left, margin_right, margin_top, margin_bottom = 90, 20, 40, 100
    max_y = max(v for _, _, v in values) if values else 1.0
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom
    bar_w = plot_w / max(1, len(values))
    lines = svg_header(width, height)
    lines.append(f'<text x="{width/2}" y="22" text-anchor="middle" font-size="18">{escape_xml(title)}</text>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top+plot_h}" x2="{margin_left+plot_w}" y2="{margin_top+plot_h}" stroke="black"/>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{margin_top+plot_h}" stroke="black"/>')
    for i in range(6):
        y = max_y * i / 5.0
        py = margin_top + plot_h * (1 - (y / max_y if max_y else 0))
        lines.append(f'<line x1="{margin_left}" y1="{py:.2f}" x2="{margin_left+plot_w}" y2="{py:.2f}" stroke="#eeeeee"/>')
        lines.append(f'<text x="{margin_left-8}" y="{py+4:.2f}" text-anchor="end" font-size="11">{y:.0f}</text>')
    for idx, (label, color, value) in enumerate(values):
        x = margin_left + idx * bar_w + bar_w * 0.1
        h = plot_h * (value / max_y if max_y else 0)
        y = margin_top + plot_h - h
        lines.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{bar_w*0.8:.2f}" height="{h:.2f}" fill="{color}"/>')
        lines.append(f'<text x="{x + bar_w*0.4:.2f}" y="{margin_top+plot_h+15}" text-anchor="end" transform="rotate(-40 {x + bar_w*0.4:.2f} {margin_top+plot_h+15})" font-size="11">{escape_xml(label)}</text>')
    lines.append(f'<text x="16" y="{height/2}" transform="rotate(-90 16 {height/2})" text-anchor="middle" font-size="12">{escape_xml(y_label)}</text>')
    lines.append('</svg>')
    write_svg(path, lines)


def make_histogram(path: Path, title: str, values: list[float], bins: int, color: str, x_label: str) -> None:
    if not values:
        return
    min_v, max_v = min(values), max(values)
    if min_v == max_v:
        max_v = min_v + 1.0
    width, height = 900, 420
    margin_left, margin_right, margin_top, margin_bottom = 70, 20, 40, 45
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom
    bucket_counts = [0] * bins
    for v in values:
        idx = min(bins - 1, int((v - min_v) / (max_v - min_v) * bins))
        bucket_counts[idx] += 1
    max_count = max(bucket_counts) or 1
    bar_w = plot_w / bins
    lines = svg_header(width, height)
    lines.append(f'<text x="{width/2}" y="22" text-anchor="middle" font-size="18">{escape_xml(title)}</text>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top+plot_h}" x2="{margin_left+plot_w}" y2="{margin_top+plot_h}" stroke="black"/>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{margin_top+plot_h}" stroke="black"/>')
    for i, count in enumerate(bucket_counts):
        h = plot_h * count / max_count
        x = margin_left + i * bar_w
        y = margin_top + plot_h - h
        lines.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{bar_w-1:.2f}" height="{h:.2f}" fill="{color}"/>')
    lines.append(f'<text x="{width/2}" y="{height-8}" text-anchor="middle" font-size="12">{escape_xml(x_label)}</text>')
    lines.append('</svg>')
    write_svg(path, lines)


def generate() -> None:
    ensure_dirs()
    runs = [load_run(spec) for spec in RUNS]
    runs_by_slug = {r.spec.slug: r for r in runs}
    primary_runs = [r for r in runs if r.spec.primary]
    state_runs = [r for r in runs if r.spec.mode in ("state-aware", "state-only")]

    # Manifest
    manifest_rows = []
    for run in runs:
        manifest_rows.append({
            "slug": run.spec.slug,
            "label": run.spec.label,
            "mode": run.spec.mode,
            "kind": run.spec.kind,
            "primary": "yes" if run.spec.primary else "no",
            "clean": "yes" if run.spec.clean else "no",
            "eval_status": run.eval_summary.get("eval_status", "NA"),
            "campaign_status": run.run_summary.get("campaign_status", "NA"),
            "campaign_seconds": run.run_summary.get("campaign_seconds", "NA"),
            "campaign_dir": str(run.campaign_dir),
        })
    write_csv(TABLES / "run-manifest.csv", manifest_rows, list(manifest_rows[0].keys()))
    write_markdown_table(TABLES / "run-manifest.md", list(manifest_rows[0].keys()), [[row[k] for k in manifest_rows[0].keys()] for row in manifest_rows])

    # Queue exploration
    queue_summary_rows = []
    queue_mut_rows = []
    queue_prod_rows = []
    interesting_rows = []
    late24_rows = []
    for run in runs:
        entries = run.queue_entries
        sizes = [e.size for e in entries]
        late12 = late_entries(entries, 12.0)
        late18 = late_entries(entries, 18.0)
        late22 = late_entries(entries, 22.0)
        queue_summary_rows.append({
            "label": run.spec.label,
            "mode": run.spec.mode,
            "queue_entries": len(entries),
            "size_min": min(sizes) if sizes else 0,
            "size_median": statistics.median(sizes) if sizes else 0,
            "size_mean": round(statistics.mean(sizes), 2) if sizes else 0,
            "size_max": max(sizes) if sizes else 0,
            "late_after_12h": len(late12),
            "late_after_18h": len(late18),
            "late_after_22h": len(late22),
            "first_queue_time": iso(min((e.mtime for e in entries), default=None)),
            "last_queue_time": iso(max((e.mtime for e in entries), default=None)),
        })
        queue_mut_rows.extend(queue_mutation_summary(run))
        prod = productive_ancestors(entries)
        for src, count in prod.most_common(20):
            queue_prod_rows.append({"label": run.spec.label, "source_id": src, "descendant_count": count})
        interesting_rows.extend(pick_interesting_queue_entries(run))
        if run.spec.slug == "20260505T045009Z-state-aware-86400s":
            for e in sorted(late12, key=lambda x: (x.hours_since_start or 0.0, x.id_num)):
                late24_rows.append({
                    "label": run.spec.label,
                    "id": e.id_num,
                    "filename": e.path.name,
                    "hours_since_start": round(e.hours_since_start or 0.0, 3),
                    "size": e.size,
                    "src_ids": "+".join(str(x) for x in e.src_ids),
                    "op": e.op or "orig",
                    "rep": e.rep,
                    "cov": "yes" if e.cov else "no",
                })
    write_csv(TABLES / "queue-size-summary.csv", queue_summary_rows, list(queue_summary_rows[0].keys()))
    write_markdown_table(TABLES / "queue-size-summary.md", list(queue_summary_rows[0].keys()), [[r[k] for k in queue_summary_rows[0].keys()] for r in queue_summary_rows])
    write_csv(TABLES / "queue-mutation-ops.csv", queue_mut_rows, list(queue_mut_rows[0].keys()))
    write_markdown_table(TABLES / "queue-mutation-ops.md", list(queue_mut_rows[0].keys()), [[r[k] for k in queue_mut_rows[0].keys()] for r in queue_mut_rows])
    write_csv(TABLES / "queue-productive-ancestors.csv", queue_prod_rows, list(queue_prod_rows[0].keys()))
    write_markdown_table(TABLES / "queue-productive-ancestors.md", list(queue_prod_rows[0].keys()), [[r[k] for k in queue_prod_rows[0].keys()] for r in queue_prod_rows[:80]])
    write_csv(TABLES / "interesting-queue-entries.csv", interesting_rows, list(interesting_rows[0].keys()))
    write_markdown_table(TABLES / "interesting-queue-entries.md", list(interesting_rows[0].keys()), [[r[k] for k in interesting_rows[0].keys()] for r in interesting_rows[:80]])
    write_csv(TABLES / "late-queue-entries-24h.csv", late24_rows, list(late24_rows[0].keys()) if late24_rows else ["label", "id"]) 
    if late24_rows:
        write_markdown_table(TABLES / "late-queue-entries-24h.md", list(late24_rows[0].keys()), [[r[k] for k in late24_rows[0].keys()] for r in late24_rows[:80]])
    else:
        (TABLES / "late-queue-entries-24h.md").write_text("No late queue entries after 12h found.\n")

    # Queue figures
    queue_size_series = []
    queue_size_time_series = []
    for run in runs:
        if not run.queue_entries:
            continue
        queue_size_series.append((run.spec.label, run.spec.color, [(e.id_num, e.size) for e in run.queue_entries]))
        queue_size_time_series.append((run.spec.label, run.spec.color, [((e.hours_since_start or 0.0), e.size) for e in run.queue_entries]))
        make_histogram(FIGURES / f"{slugify(run.spec.slug)}-queue-size-histogram.svg", f"{run.spec.label}: queue entry size histogram", [float(e.size) for e in run.queue_entries], 20, run.spec.color, "queue entry size (bytes)")
    make_scatter_chart(FIGURES / "queue-size-vs-id.svg", "Queue entry size vs discovery id", queue_size_series, "size (bytes)")
    make_scatter_chart(FIGURES / "24h-queue-size-vs-hour.svg", "Queue entry size vs discovery hour", [series for series in queue_size_time_series if series[0].startswith("24h state+coverage")], "size (bytes)")

    # New paths per hour / late discovery
    run24 = runs_by_slug["20260505T045009Z-state-aware-86400s"]
    hourly_new_paths = Counter(int(e.hours_since_start or 0.0) for e in run24.queue_entries)
    new_path_rows = [{"hour_bucket": h, "new_queue_entries": hourly_new_paths[h]} for h in sorted(hourly_new_paths)]
    write_csv(TABLES / "24h-new-paths-per-hour.csv", new_path_rows, ["hour_bucket", "new_queue_entries"])
    write_markdown_table(TABLES / "24h-new-paths-per-hour.md", ["hour_bucket", "new_queue_entries"], [[r["hour_bucket"], r["new_queue_entries"]] for r in new_path_rows])
    make_bar_chart(FIGURES / "24h-new-paths-per-hour.svg", "24h state+coverage: queue discoveries per hour", [(str(r["hour_bucket"]), "#9467bd", float(r["new_queue_entries"])) for r in new_path_rows], "new queue entries")

    # State machine analyses
    sm_rows = [state_machine_summary(run) for run in state_runs if state_machine_summary(run)]
    write_csv(TABLES / "state-machine-summary.csv", sm_rows, list(sm_rows[0].keys()))
    write_markdown_table(TABLES / "state-machine-summary.md", list(sm_rows[0].keys()), [[r[k] for k in sm_rows[0].keys()] for r in sm_rows])
    deg_rows = []
    for run in state_runs:
        deg_rows.extend(state_degree_rows(run))
    if deg_rows:
        write_csv(TABLES / "state-machine-degree-rankings.csv", deg_rows, list(deg_rows[0].keys()))
        write_markdown_table(TABLES / "state-machine-degree-rankings.md", list(deg_rows[0].keys()), [[r[k] for k in deg_rows[0].keys()] for r in deg_rows[:80]])

    diff_rows = []
    sm_12_sc = runs_by_slug["20260503T054121Z-state-aware-43200s"].state_machine
    sm_24_sc = runs_by_slug["20260505T045009Z-state-aware-86400s"].state_machine
    sm_12_so = runs_by_slug["20260503T054506Z-state-only-43200s"].state_machine
    if sm_12_sc and sm_24_sc:
        only_24 = sorted(sm_24_sc.edges - sm_12_sc.edges)
        only_12 = sorted(sm_12_sc.edges - sm_24_sc.edges)
        both = sorted(sm_12_sc.edges & sm_24_sc.edges)
        diff_rows.append({"comparison": "24h-state-coverage-vs-12h-state-coverage", "shared_edges": len(both), "lhs_only_edges": len(only_24), "rhs_only_edges": len(only_12)})
        for src, dst in only_24:
            diff_rows.append({"comparison": "24h-only-edge", "shared_edges": "", "lhs_only_edges": f"{src}->{dst}", "rhs_only_edges": ""})
        for src, dst in only_12:
            diff_rows.append({"comparison": "12h-only-edge", "shared_edges": "", "lhs_only_edges": "", "rhs_only_edges": f"{src}->{dst}"})
    if sm_24_sc and sm_12_so:
        diff_rows.append({"comparison": "24h-state-coverage-vs-12h-state-only", "shared_edges": len(sm_24_sc.edges & sm_12_so.edges), "lhs_only_edges": len(sm_24_sc.edges - sm_12_so.edges), "rhs_only_edges": len(sm_12_so.edges - sm_24_sc.edges)})
    if diff_rows:
        write_csv(TABLES / "state-machine-edge-diff.csv", diff_rows, list(diff_rows[0].keys()))
        write_markdown_table(TABLES / "state-machine-edge-diff.md", list(diff_rows[0].keys()), [[r[k] for k in diff_rows[0].keys()] for r in diff_rows[:60]])

    for run in state_runs:
        src = run.campaign_dir / "aflnet-out" / "ipsm.dot"
        svg = FIGURES / f"state-machine-{slugify(run.spec.short_label)}.svg"
        render_dot(src, svg)
    diff1 = DATA / "state-machine-24h-vs-12h-sc.dot"
    make_diff_state_machine(runs_by_slug["20260505T045009Z-state-aware-86400s"], runs_by_slug["20260503T054121Z-state-aware-43200s"], diff1)
    render_dot(diff1, FIGURES / "state-machine-24h-vs-12h-sc-diff.svg")
    diff2 = DATA / "state-machine-24h-sc-vs-12h-so.dot"
    make_diff_state_machine(runs_by_slug["20260505T045009Z-state-aware-86400s"], runs_by_slug["20260503T054506Z-state-only-43200s"], diff2)
    render_dot(diff2, FIGURES / "state-machine-24h-sc-vs-12h-so-diff.svg")

    state_node_series = []
    state_edge_series = []
    for run in state_runs:
        state_node_series.append((run.spec.label, run.spec.color, [(row["hours_since_start"], row["n_nodes"]) for row in run.plot_rows]))
        state_edge_series.append((run.spec.label, run.spec.color, [(row["hours_since_start"], row["n_edges"]) for row in run.plot_rows]))
    make_multi_line_chart(FIGURES / "state-nodes-vs-hours-all-state-runs.svg", "Derived state nodes vs hours", state_node_series, "state nodes")
    make_multi_line_chart(FIGURES / "state-edges-vs-hours-all-state-runs.svg", "Derived state edges vs hours", state_edge_series, "state edges")

    # Exception novelty
    exc_events_by_run: dict[str, list[ExceptionEvent]] = {run.spec.slug: extract_exception_events(run) for run in runs}
    signature_counts_by_run: dict[str, Counter[str]] = {}
    signature_rows = []
    all_sigs: set[str] = set()
    for run in runs:
        counter = Counter(f"{e.exc_class}|{e.top_frame}|{e.message_norm}|{e.context_kind}" for e in exc_events_by_run[run.spec.slug])
        signature_counts_by_run[run.spec.slug] = counter
        all_sigs |= set(counter)
    for sig in sorted(all_sigs):
        exc_class, top_frame, message_norm, context_kind = sig.split("|", 3)
        row = {"signature": sig, "exc_class": exc_class, "top_frame": top_frame, "message_norm": message_norm, "context_kind": context_kind}
        total = 0
        presence = 0
        for run in runs:
            count = signature_counts_by_run[run.spec.slug].get(sig, 0)
            row[run.spec.short_label] = count
            total += count
            presence += 1 if count else 0
        row["total_count"] = total
        row["present_in_run_count"] = presence
        signature_rows.append(row)
    if signature_rows:
        signature_fields = ["signature", "exc_class", "top_frame", "message_norm", "context_kind"] + [r.spec.short_label for r in runs] + ["total_count", "present_in_run_count"]
        write_csv(TABLES / "exception-signature-summary.csv", signature_rows, signature_fields)
        write_markdown_table(TABLES / "exception-signature-summary.md", signature_fields[:8], [[r.get(k, "") for k in signature_fields[:8]] for r in signature_rows[:60]])

    novelty_rows = []
    for run in runs:
        own = set(signature_counts_by_run[run.spec.slug])
        other = set().union(*(set(signature_counts_by_run[o.spec.slug]) for o in runs if o.spec.slug != run.spec.slug))
        novel = sorted(own - other)
        for sig in novel:
            exc_class, top_frame, message_norm, context_kind = sig.split("|", 3)
            novelty_rows.append({
                "label": run.spec.label,
                "exc_class": exc_class,
                "top_frame": top_frame,
                "message_norm": message_norm,
                "context_kind": context_kind,
                "count": signature_counts_by_run[run.spec.slug][sig],
            })
    if novelty_rows:
        fields = list(novelty_rows[0].keys())
        write_csv(TABLES / "exception-signature-novelty.csv", novelty_rows, fields)
        write_markdown_table(TABLES / "exception-signature-novelty.md", fields, [[r[k] for k in fields] for r in novelty_rows[:80]])

    top_exc_rows = []
    for run in runs:
        for sig, count in signature_counts_by_run[run.spec.slug].most_common(15):
            exc_class, top_frame, message_norm, context_kind = sig.split("|", 3)
            top_exc_rows.append({
                "label": run.spec.label,
                "exc_class": exc_class,
                "top_frame": top_frame,
                "message_norm": message_norm,
                "context_kind": context_kind,
                "count": count,
            })
    if top_exc_rows:
        fields = list(top_exc_rows[0].keys())
        write_csv(TABLES / "top-exception-signatures.csv", top_exc_rows, fields)
        write_markdown_table(TABLES / "top-exception-signatures.md", fields, [[r[k] for k in fields] for r in top_exc_rows[:60]])
        label_to_color = {run.spec.label: run.spec.color for run in runs}
        make_bar_chart(FIGURES / "exception-signatures-by-run.svg", "Top exception signature counts by run", [(r["label"] + ":" + r["exc_class"].split(".")[-1], label_to_color.get(r["label"], "#999999"), float(r["count"])) for r in top_exc_rows[:12]], "count")

    novel_sections = []
    for row in novelty_rows[:20]:
        run = runs_by_slug[next(r.spec.slug for r in runs if r.spec.label == row["label"])]
        matches = [e for e in exc_events_by_run[run.spec.slug] if e.exc_class == row["exc_class"] and e.top_frame == row["top_frame"] and e.message_norm == row["message_norm"]]
        if matches:
            e = matches[0]
            novel_sections.append(f"## {row['label']} :: {row['exc_class']}\n\n- top_frame={row['top_frame']}\n- message_norm={row['message_norm']}\n- context_kind={row['context_kind']}\n- line_no={e.line_no}\n\n```text\n{e.context_line}\n{e.raw_line}\n```\n")
    (LISTINGS / "novel-exception-excerpts.md").write_text("\n".join(novel_sections) if novel_sections else "No novel exception signatures found across runs.\n")

    # Hang artifacts
    hang_summary_rows = []
    hang_dup_rows = []
    hang_candidate_rows = []
    for run in runs:
        hang_summary_rows.append({
            "label": run.spec.label,
            "replayable_hang_count": run.hang_analysis.get("replayable_hang_count", "0"),
            "unique_hang_hash_count": run.hang_analysis.get("unique_hang_hash_count", "0"),
            "duplicate_hang_count": run.hang_analysis.get("duplicate_hang_count", "0"),
            "hang_size_min": run.hang_analysis.get("hang_size_min", "0"),
            "hang_size_max": run.hang_analysis.get("hang_size_max", "0"),
            "first_hang_artifact_time": run.hang_analysis.get("first_hang_artifact_time", "NA"),
            "last_hang_artifact_time": run.hang_analysis.get("last_hang_artifact_time", "NA"),
        })
        hang_dup_rows.extend(hang_artifact_hash_rows(run))
        if run.spec.slug == "20260505T045009Z-state-aware-86400s":
            hang_candidate_rows.extend(choose_hang_candidates(run))
    write_csv(TABLES / "hang-artifact-summary.csv", hang_summary_rows, list(hang_summary_rows[0].keys()))
    write_markdown_table(TABLES / "hang-artifact-summary.md", list(hang_summary_rows[0].keys()), [[r[k] for k in hang_summary_rows[0].keys()] for r in hang_summary_rows])
    if hang_dup_rows:
        write_csv(TABLES / "hang-artifact-duplicates.csv", hang_dup_rows, list(hang_dup_rows[0].keys()))
        write_markdown_table(TABLES / "hang-artifact-duplicates.md", list(hang_dup_rows[0].keys()), [[r[k] for k in hang_dup_rows[0].keys()] for r in hang_dup_rows[:80]])
    if hang_candidate_rows:
        fields = list(hang_candidate_rows[0].keys())
        write_csv(TABLES / "hang-replay-triage-candidates.csv", hang_candidate_rows, fields)
        write_markdown_table(TABLES / "hang-replay-triage-candidates.md", fields, [[r[k] for k in fields] for r in hang_candidate_rows[:80]])
        sizes = [float(r["size"]) for r in hang_candidate_rows]
        make_histogram(FIGURES / "hang-artifact-size-histogram.svg", "Targeted clean-24h hang candidate sizes", sizes, 20, "#9467bd", "hang artifact size (bytes)")

    # Module-level coverage
    module_rows = []
    MODULES = {'proxy': 'com.velocitypowered.proxy', 'api': 'com.velocitypowered.api', 'native': 'com.velocitypowered.native'}
    def module_of(pkg):
        for mod, prefix in MODULES.items():
            if pkg.startswith(prefix):
                return mod
        return 'other'
    for run in runs:
        xml = run.campaign_dir / 'coverage' / 'jacoco.xml'
        if not xml.exists():
            continue
        root = ET.parse(xml).getroot()
        mod_data = {m: Counter() for m in ['proxy', 'api', 'native', 'other']}
        for pkg in root.findall('.//package'):
            pkg_name = pkg.get('name', '').replace('/', '.')
            if not pkg_name.startswith('com.velocitypowered.'):
                continue
            mod = module_of(pkg_name)
            for counter in pkg.iter('counter'):
                ctype = counter.get('type')
                covered = int(counter.get('covered', 0))
                missed = int(counter.get('missed', 0))
                mod_data[mod][ctype] += covered
                mod_data[mod][f'{ctype}_missed'] = mod_data[mod].get(f'{ctype}_missed', 0) + missed
        for mod in ['proxy', 'api', 'native']:
            for metric in ['INSTRUCTION', 'LINE', 'BRANCH', 'CLASS']:
                covered = mod_data[mod].get(metric, 0)
                missed = mod_data[mod].get(f'{metric}_missed', 0)
                total = covered + missed
                pct = (covered / total * 100) if total > 0 else 0.0
                module_rows.append({'label': run.spec.label, 'module': mod, 'metric': metric, 'covered': covered, 'total': total, 'pct': round(pct, 1)})
    if module_rows:
        fields = list(module_rows[0].keys())
        write_csv(TABLES / 'module-coverage.csv', module_rows, fields)
        write_markdown_table(TABLES / 'module-coverage.md', fields, [[r[k] for k in fields] for r in module_rows])

    # Coverage / line detail analyses
    top_pkg_rows = []
    top_cls_rows = []
    for run in runs:
        campaign_only = read_line_set(run.campaign_dir / "coverage" / "line-details" / "campaign-only-covered-lines.txt")
        pkg_counts = Counter(package_of(line) for line in campaign_only)
        cls_counts = Counter(class_of(line) for line in campaign_only)
        for pkg, count in pkg_counts.most_common(20):
            top_pkg_rows.append({"label": run.spec.label, "package": pkg, "campaign_only_line_count": count})
        for cls, count in cls_counts.most_common(20):
            top_cls_rows.append({"label": run.spec.label, "class": cls, "campaign_only_line_count": count})
    write_csv(TABLES / "top-campaign-only-packages.csv", top_pkg_rows, list(top_pkg_rows[0].keys()))
    write_markdown_table(TABLES / "top-campaign-only-packages.md", list(top_pkg_rows[0].keys()), [[r[k] for k in top_pkg_rows[0].keys()] for r in top_pkg_rows[:80]])
    write_csv(TABLES / "top-campaign-only-classes.csv", top_cls_rows, list(top_cls_rows[0].keys()))
    write_markdown_table(TABLES / "top-campaign-only-classes.md", list(top_cls_rows[0].keys()), [[r[k] for k in top_cls_rows[0].keys()] for r in top_cls_rows[:80]])

    def line_diff_rows(lhs: RunArtifacts, rhs: RunArtifacts, name: str) -> list[dict[str, object]]:
        lhs_lines = read_line_set(lhs.campaign_dir / "coverage" / "line-details" / "campaign-covered-lines.txt")
        rhs_lines = read_line_set(rhs.campaign_dir / "coverage" / "line-details" / "campaign-covered-lines.txt")
        lhs_only = sorted(lhs_lines - rhs_lines)
        rhs_only = sorted(rhs_lines - lhs_lines)
        rows = [{"comparison": name, "lhs_only_count": len(lhs_only), "rhs_only_count": len(rhs_only), "lhs": lhs.spec.label, "rhs": rhs.spec.label}]
        for line in lhs_only[:200]:
            rows.append({"comparison": "lhs_only_line", "lhs_only_count": line, "rhs_only_count": "", "lhs": lhs.spec.label, "rhs": rhs.spec.label})
        for line in rhs_only[:200]:
            rows.append({"comparison": "rhs_only_line", "lhs_only_count": "", "rhs_only_count": line, "lhs": lhs.spec.label, "rhs": rhs.spec.label})
        return rows

    rows_24_12 = line_diff_rows(runs_by_slug["20260505T045009Z-state-aware-86400s"], runs_by_slug["20260503T054121Z-state-aware-43200s"], "24h-vs-12h-state-coverage")
    write_csv(TABLES / "24h-vs-12h-line-diff.csv", rows_24_12, list(rows_24_12[0].keys()))
    write_markdown_table(TABLES / "24h-vs-12h-line-diff.md", list(rows_24_12[0].keys()), [[r[k] for k in rows_24_12[0].keys()] for r in rows_24_12[:80]])
    rows_cov_sc = line_diff_rows(runs_by_slug["20260503T054505Z-code-only-43200s"], runs_by_slug["20260503T054121Z-state-aware-43200s"], "coverage-only-vs-12h-state-coverage")
    write_csv(TABLES / "coverage-only-vs-state-coverage-line-diff.csv", rows_cov_sc, list(rows_cov_sc[0].keys()))
    write_markdown_table(TABLES / "coverage-only-vs-state-coverage-line-diff.md", list(rows_cov_sc[0].keys()), [[r[k] for k in rows_cov_sc[0].keys()] for r in rows_cov_sc[:80]])

    networking_rows = []
    for run in runs:
        covered_path = run.campaign_dir / "coverage" / "line-details" / "campaign-covered-lines.txt"
        covered = read_line_set(covered_path)
        available = covered_path.exists()
        networking_rows.append({
            "label": run.spec.label,
            "connection_lines": sum(1 for line in covered if "/proxy/connection/" in line) if available else "NA",
            "protocol_lines": sum(1 for line in covered if "/proxy/protocol/" in line) if available else "NA",
            "api_lines": sum(1 for line in covered if "/api/" in line) if available else "NA",
        })
    write_csv(TABLES / "networking-protocol-focused-coverage.csv", networking_rows, list(networking_rows[0].keys()))
    write_markdown_table(TABLES / "networking-protocol-focused-coverage.md", list(networking_rows[0].keys()), [[r[k] for k in networking_rows[0].keys()] for r in networking_rows])

    # Diminishing returns / fractions
    dim_rows = []
    fraction_rows = []
    for run in primary_runs:
        final_paths = int(run.plot_rows[-1]["paths_total"]) if run.plot_rows else 0
        final_nodes = int(run.plot_rows[-1]["n_nodes"]) if run.plot_rows and run.spec.mode != "code-only" else 0
        final_edges = int(run.plot_rows[-1]["n_edges"]) if run.plot_rows and run.spec.mode != "code-only" else 0
        last_path_time = parse_float(run.fuzzer_stats.get("last_path"))
        dim_rows.append({
            "label": run.spec.label,
            "campaign_hours": (parse_float(run.run_summary.get("campaign_seconds")) or 0.0) / 3600.0,
            "final_paths": final_paths,
            "paths_at_12h": next((int(row["paths_total"]) for row in run.plot_rows if row["hours_since_start"] >= 12.0), final_paths),
            "paths_at_18h": next((int(row["paths_total"]) for row in run.plot_rows if row["hours_since_start"] >= 18.0), final_paths),
            "last_path_time": iso(last_path_time),
            "state_nodes_final": final_nodes,
            "state_edges_final": final_edges,
        })
        campaign_hours = (parse_float(run.run_summary.get("campaign_seconds")) or 0.0) / 3600.0
        for hour_mark in [1, 3, 6, 12, 18, 22]:
            row = next((row for row in run.plot_rows if row["hours_since_start"] >= hour_mark), None)
            if row is None and campaign_hours and hour_mark >= campaign_hours:
                row = run.plot_rows[-1] if run.plot_rows else None
            fraction_rows.append({
                "label": run.spec.label,
                "hour_mark": hour_mark,
                "paths_fraction_of_final": (row["paths_total"] / final_paths if row and final_paths else None),
                "nodes_fraction_of_final": (row["n_nodes"] / final_nodes if row and final_nodes else None),
                "edges_fraction_of_final": (row["n_edges"] / final_edges if row and final_edges else None),
            })
    write_csv(TABLES / "diminishing-returns-summary.csv", dim_rows, list(dim_rows[0].keys()))
    write_markdown_table(TABLES / "diminishing-returns-summary.md", list(dim_rows[0].keys()), [[r[k] for k in dim_rows[0].keys()] for r in dim_rows])
    write_csv(TABLES / "fraction-final-by-hour.csv", fraction_rows, list(fraction_rows[0].keys()))
    write_markdown_table(TABLES / "fraction-final-by-hour.md", list(fraction_rows[0].keys()), [[r[k] for k in fraction_rows[0].keys()] for r in fraction_rows[:40]])

    frac_path_series = []
    for run in primary_runs:
        if not run.plot_rows:
            continue
        final_paths = run.plot_rows[-1]["paths_total"] or 1.0
        frac_path_series.append((run.spec.label, run.spec.color, [(row["hours_since_start"], 100.0 * row["paths_total"] / final_paths) for row in run.plot_rows]))
    make_multi_line_chart(FIGURES / "paths-fraction-of-final-vs-hours.svg", "Path discovery as % of final paths", frac_path_series, "% of final paths_total")

    # Targeted hang replay results if available
    targeted_replay_dir = REPLAY_LOGS / "clean-24h-targeted-triage"
    targeted_summary, targeted_samples = read_targeted_replay(targeted_replay_dir)
    if targeted_summary:
        targeted_summary_rows = [{
            "hang_replay_classification_status": targeted_summary.get("hang_replay_classification_status", "NA"),
            "replay_sample_count": targeted_summary.get("replay_sample_count", "NA"),
            "replay_success_count": targeted_summary.get("replay_success_count", "NA"),
            "replay_timeout_count": targeted_summary.get("replay_timeout_count", "NA"),
            "replay_no_response_exit_count": targeted_summary.get("replay_no_response_exit_count", "NA"),
            "replay_distinct_response_sequences": targeted_summary.get("replay_distinct_response_sequences", "NA"),
            "target_reachable_after_replay": targeted_summary.get("target_reachable_after_replay", "NA"),
            "hang_replay_interpretation": targeted_summary.get("hang_replay_interpretation", "NA"),
        }]
        write_csv(TABLES / "hang-replay-targeted-summary.csv", targeted_summary_rows, list(targeted_summary_rows[0].keys()))
        write_markdown_table(TABLES / "hang-replay-targeted-summary.md", list(targeted_summary_rows[0].keys()), [[targeted_summary_rows[0][k] for k in targeted_summary_rows[0].keys()]])
    if targeted_samples:
        fields = list(targeted_samples[0].keys())
        write_csv(TABLES / "hang-replay-targeted-samples.csv", targeted_samples, fields)
        write_markdown_table(TABLES / "hang-replay-targeted-samples.md", fields, [[r[k] for k in fields] for r in targeted_samples])
        group_counter = Counter((row["group"], row["class"]) for row in targeted_samples)
        group_rows = [{"group": group, "result_class": cls, "count": count} for (group, cls), count in sorted(group_counter.items())]
        write_csv(TABLES / "hang-replay-targeted-by-group.csv", group_rows, list(group_rows[0].keys()))
        write_markdown_table(TABLES / "hang-replay-targeted-by-group.md", list(group_rows[0].keys()), [[r[k] for k in group_rows[0].keys()] for r in group_rows])
        replay_excerpt_sections = []
        for row in targeted_samples[:10]:
            log_path = targeted_replay_dir / row["log"]
            excerpt = []
            if log_path.exists():
                excerpt = log_path.read_text(errors="replace").splitlines()[:40]
            replay_excerpt_sections.append(f"## {row['filename']} :: {row['class']}\n\n- group={row['group']}\n- response_sequence={row['response_sequence']}\n- log={row['log']}\n\n```text\n" + "\n".join(excerpt) + "\n```\n")
        (LISTINGS / "hang-replay-targeted-excerpts.md").write_text("\n".join(replay_excerpt_sections))

    # Clean vs recovered 24h comparison
    clean24 = runs_by_slug["20260505T045009Z-state-aware-86400s"]
    rec24 = runs_by_slug["20260503T045624Z-state-aware-86400s"]
    clean_vs_rec = [{
        "clean_label": clean24.spec.label,
        "recovered_label": rec24.spec.label,
        "clean_eval_status": clean24.eval_summary.get("eval_status", "NA"),
        "recovered_eval_status": rec24.eval_summary.get("eval_status", "NA"),
        "clean_execs_done": clean24.run_summary.get("execs_done", "NA"),
        "recovered_execs_done": rec24.run_summary.get("execs_done", "NA"),
        "clean_queue_paths_found": clean24.run_summary.get("queue_paths_found", "NA"),
        "recovered_queue_paths_found": rec24.run_summary.get("queue_paths_found", "NA"),
        "clean_state_edges": clean24.run_summary.get("state_coverage_edges", "NA"),
        "recovered_state_edges": rec24.run_summary.get("state_coverage_edges", "NA"),
        "clean_bitmap_changed_cells": clean24.run_summary.get("afl_fuzz_bitmap_changed_cells", "NA"),
        "recovered_bitmap_changed_cells": rec24.run_summary.get("afl_fuzz_bitmap_changed_cells", "NA"),
        "clean_jacoco_xml_present": "yes" if (clean24.campaign_dir / "coverage" / "jacoco.xml").exists() else "no",
        "recovered_jacoco_xml_present": "yes" if (rec24.campaign_dir / "coverage" / "jacoco.xml").exists() else "no",
    }]
    write_csv(TABLES / "24h-clean-vs-recovered-summary.csv", clean_vs_rec, list(clean_vs_rec[0].keys()))
    write_markdown_table(TABLES / "24h-clean-vs-recovered-summary.md", list(clean_vs_rec[0].keys()), [[r[k] for k in clean_vs_rec[0].keys()] for r in clean_vs_rec])
    make_multi_line_chart(FIGURES / "24h-clean-vs-recovered-paths.svg", "24h clean vs recovered: paths_total vs hours", [(clean24.spec.label, clean24.spec.color, [(r["hours_since_start"], r["paths_total"]) for r in clean24.plot_rows]), (rec24.spec.label, rec24.spec.color, [(r["hours_since_start"], r["paths_total"]) for r in rec24.plot_rows])], "paths_total")
    make_multi_line_chart(FIGURES / "24h-clean-vs-recovered-state-edges.svg", "24h clean vs recovered: state edges vs hours", [(clean24.spec.label, clean24.spec.color, [(r["hours_since_start"], r["n_edges"]) for r in clean24.plot_rows]), (rec24.spec.label, rec24.spec.color, [(r["hours_since_start"], r["n_edges"]) for r in rec24.plot_rows])], "state edges")
    make_multi_line_chart(FIGURES / "24h-clean-vs-recovered-throughput.svg", "24h clean vs recovered: execs/sec vs hours", [(clean24.spec.label, clean24.spec.color, [(r["hours_since_start"], r["execs_per_sec"]) for r in clean24.plot_rows]), (rec24.spec.label, rec24.spec.color, [(r["hours_since_start"], r["execs_per_sec"]) for r in rec24.plot_rows])], "execs/sec")

    # Target diagnostics by hour (primary runs only)
    diag_rows = []
    for run in [r for r in runs if r.spec.primary]:
        per_hour = defaultdict(lambda: {"connection_reset": 0, "timeout": 0, "backend_or_session": 0, "handled_client": 0})
        for log_path in [run.campaign_dir / "logs" / "velocity.log", run.campaign_dir / "logs" / "flying-squid.log", run.campaign_dir / "logs" / "aflnet.log"]:
            for rel_secs, _level, msg in parse_log_events(log_path):
                hour = int(rel_secs // 3600)
                for key, pattern in TARGET_CLASS_PATTERNS.items():
                    if pattern.search(msg):
                        per_hour[hour][key] += 1
        for hour, counts in sorted(per_hour.items()):
            diag_rows.append({"label": run.spec.label, "hour": hour, **counts})
    if diag_rows:
        fields = ["label", "hour", "connection_reset", "timeout", "backend_or_session", "handled_client"]
        write_csv(TABLES / "target-diagnostics-by-hour.csv", diag_rows, fields)
        write_markdown_table(TABLES / "target-diagnostics-by-hour.md", fields, [[r[k] for k in fields] for r in diag_rows[:120]])
        # Figure only for clean 24h
        clean_diag = [r for r in diag_rows if r["label"] == clean24.spec.label]
        make_multi_line_chart(FIGURES / "target-diagnostics-by-hour.svg", "24h clean run: target diagnostics by hour", [
            ("connection_reset", "#d62728", [(r["hour"], r["connection_reset"]) for r in clean_diag]),
            ("timeout", "#9467bd", [(r["hour"], r["timeout"]) for r in clean_diag]),
            ("backend_or_session", "#1f77b4", [(r["hour"], r["backend_or_session"]) for r in clean_diag]),
            ("handled_client", "#2ca02c", [(r["hour"], r["handled_client"]) for r in clean_diag]),
        ], "count per hour")

    # Listings / data
    sample_sections = []
    for row in interesting_rows[:60]:
        sample_sections.append(f"## {row['label']} :: {row['group']} :: id {row['id']}\n\n- filename={row['filename']}\n- size={row['size']}\n- hours_since_start={row['hours_since_start']}\n- src_ids={row['src_ids']}\n- op={row['op']}\n- rep={row['rep']}\n- cov={row['cov']}\n- path={row['path']}\n")
    (LISTINGS / "interesting-queue-entry-samples.md").write_text("\n".join(sample_sections))

    # Save per-run queue data
    for run in runs:
        rows = []
        for e in run.queue_entries:
            rows.append({
                "id": e.id_num,
                "filename": e.path.name,
                "size": e.size,
                "mtime": e.mtime,
                "iso_mtime": iso(e.mtime),
                "hours_since_start": round(e.hours_since_start or 0.0, 6),
                "orig": e.orig or "",
                "src_ids": "+".join(str(x) for x in e.src_ids),
                "op": e.op or "orig",
                "rep": e.rep,
                "cov": e.cov,
            })
        if rows:
            write_csv(DATA / f"{run.spec.slug}-queue-entries.csv", rows, list(rows[0].keys()))

    # README + report
    readme = [
        "# Evaluation Artifact Deep Dive",
        "",
        "Generated evidence bundle for seed/queue exploration, derived state machines, exception novelty, hang artifacts, coverage location deltas, diminishing returns, and clean-vs-recovered 24h comparisons.",
        "",
        "## Source Runs",
        "",
    ]
    for run in runs:
        readme.append(f"- `{run.spec.slug}` — {run.spec.label}")
    readme.extend([
        "",
        "## Key caveats",
        "",
        "- `replayable-hangs/` means retained replayable hang artifacts, not repeated/reproduced hangs.",
        "- `unique_hangs=500` is capped by AFLNet retention policy.",
        "- JaCoCo coverage is whole-process reporting, not AFLNet mutation guidance.",
        "- The recovered 24h run is useful only as a caveated wrapper-failure comparison.",
        "- Derived `ipsm.dot` state-node numbers should be treated carefully across runs; graph counts and within-run shapes are safer than assuming raw numeric node IDs are semantically stable across independent runs.",
        "",
        "## Important outputs",
        "",
        "- `tables/queue-size-summary.md` / `.csv`",
        "- `tables/interesting-queue-entries.md` / `.csv`",
        "- `tables/late-queue-entries-24h.md` / `.csv`",
        "- `tables/state-machine-summary.md` / `.csv`",
        "- `tables/exception-signature-summary.csv`",
        "- `tables/hang-artifact-summary.md` / `.csv`",
        "- `tables/hang-replay-triage-candidates.md` / `.csv`",
        "- `tables/hang-replay-targeted-summary.md` / `.csv`",
        "- `tables/hang-replay-targeted-samples.md` / `.csv`",
        "- `tables/hang-replay-targeted-by-group.md` / `.csv`",
        "- `tables/24h-clean-vs-recovered-summary.md` / `.csv`",
        "- `figures/state-machine-*.svg`",
        "- `figures/24h-clean-vs-recovered-*.svg`",
        "- `investigation-report.md`",
    ])
    (OUT_ROOT / "README.md").write_text("\n".join(readme) + "\n")

    report_lines = [
        "# Investigation Report",
        "",
        "## Executive Summary",
        "",
        "- The clean 24h local-staging state+coverage run completed with `eval_status=PASS` and `campaign_status=PASS`.",
        "- Queue/seed exploration shows most retained queue entries come from havoc mutations early, while late 24h discoveries still occurred after hour 12 and continued almost to the end of the run.",
        "- Derived state machines grew quickly early, then plateaued; the clean 24h run finished with 16 nodes / 27 edges, only modestly above the 12h state+coverage run on edge count and not above it on node count.",
        "- Coverage-only remained competitive on queue and coverage metrics, reinforcing that Java code-edge feedback appears to drive much of the productive exploration.",
        "- The clean 24h run retained 500 replayable hang artifacts but only 494 unique byte hashes, so duplicates exist but most retained hang artifacts are byte-distinct; retained-hang counts remain a capped diagnostic, not a bug count.",
        "- Targeted replay triage of 27 clean-24h hang candidates produced 7 successful replays and 20 strict no-response exits, with zero reproduced timeouts and the target remaining reachable.",
        "- Exception signatures are dominated by repeated handled `ClassCastException` server-connection events; novelty analysis should be interpreted cautiously because repetition is high and fatal exception counts remain zero.",
        "",
        "## Evidence Highlights",
        "",
        f"- Clean 24h final metrics: see `{TABLES / '24h-clean-vs-recovered-summary.md'}` and `{EVAL_ROOT / '20260505T045009Z-state-aware-86400s' / 'campaign' / 'run-summary.txt'}`.",
        f"- Late queue entries and sizes: see `{TABLES / 'late-queue-entries-24h.md'}` and `{FIGURES / '24h-queue-size-vs-hour.svg'}`.",
        f"- State machine growth and overlaps: see `{TABLES / 'state-machine-summary.md'}`, `{TABLES / 'state-machine-edge-diff.md'}`, and state-machine SVGs under `{FIGURES}`.",
        f"- Exception signature counts and novelty: see `{TABLES / 'exception-signature-summary.csv'}` and `{TABLES / 'exception-signature-novelty.md'}`.",
        f"- Hang artifact size/duplicate/candidate triage: see `{TABLES / 'hang-artifact-summary.md'}`, `{TABLES / 'hang-artifact-duplicates.md'}`, `{TABLES / 'hang-replay-triage-candidates.md'}`, and `{TABLES / 'hang-replay-targeted-summary.md'}`.",
        f"- Coverage-location comparisons: see `{TABLES / '24h-vs-12h-line-diff.md'}`, `{TABLES / 'coverage-only-vs-state-coverage-line-diff.md'}`, and `{TABLES / 'networking-protocol-focused-coverage.md'}`.",
        "",
        "## Interpretation Notes",
        "",
        "- Queue-growth and state-growth are not the same phenomenon. The clean 24h run continued finding queue entries late, but the derived packet-ID state graph saturated much earlier.",
        "- Cross-run `ipsm.dot` edge-identity diffs should be treated as raw numeric-state-graph diffs, not as a proof that semantically identical protocol states were or were not shared across runs.",
        "- The clean 24h run improved on the recovered failed 24h run in queue paths, edge count, throughput, and artifact completeness, which supports the local-staging workflow change as an infrastructure improvement.",
        "- Coverage-only remaining competitive should be discussed explicitly in the report; it is not enough to assume state-awareness dominates because the state abstraction is richer conceptually.",
        "- `replayable-hangs/` should be discussed as a retained artifact pool needing replay triage, not as repeated evidence of a single reproducible target hang.",
        "- The targeted replay sample suggests many retained hang artifacts collapse into strict no-response outcomes rather than reproduced timeouts; that should shape the hang discussion.",
        "",
        "## Deferred / next-step work",
        "",
        "- Broaden targeted replay beyond the first curated 27 clean-24h candidates if the report needs stronger hang interpretation coverage.",
        "- Deeper per-package/per-class line-delta discussion for networking/protocol-heavy regions.",
        "- Optional expansion of exception novelty to include full normalized-message clustering across handled disconnect categories.",
    ]
    report_lines.append("")
    report_lines.append("## Deep-Dive Analyses")
    report_lines.append("")
    report_lines.append("- State machine interpretation guide: `state-machine-interpretation.md`")
    report_lines.append("- Duplicate hang deep dive: `duplicate-hang-deep-dive.md`")
    report_lines.append("- Whole-Velocity coverage comparison: `velocity-coverage-comparison.md`")
    (OUT_ROOT / "investigation-report.md").write_text("\n".join(report_lines) + "\n")


if __name__ == "__main__":
    generate()
