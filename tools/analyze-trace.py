#!/usr/bin/env python3
"""Run the unified InkSign Perfetto report with one trace load."""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


REQUIRED_SECTIONS = (
    "trace",
    "prediction",
    "native_timing",
    "front_buffer",
    "lifecycle",
    "frames",
    "cpu",
    "hot_paths",
    "allocation",
)
CSV_COLUMNS = ("section", "metric", "scope", "value", "unit")
NUMBER_RE = re.compile(r"^-?(?:\d+\.\d+|\d+)(?:[eE][+-]?\d+)?$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="Perfetto trace file")
    parser.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="report format (default: markdown)",
    )
    return parser.parse_args()


def parse_value(raw: str) -> Any:
    if raw == "" or raw.upper() in ("NULL", "[NULL]"):
        return None
    if not NUMBER_RE.match(raw):
        return raw
    number = float(raw)
    return int(number) if number.is_integer() else number


def run_query(trace: Path, sql_file: Path, processor: Path) -> list[dict[str, Any]]:
    command = [sys.executable, str(processor), "query", "-f", str(sql_file), str(trace)]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=None, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"trace processor failed with exit code {result.returncode}")

    rows: list[dict[str, Any]] = []
    reader = csv.DictReader(result.stdout.splitlines())
    if reader.fieldnames != list(CSV_COLUMNS):
        raise RuntimeError(
            "malformed trace report header: "
            f"expected {CSV_COLUMNS}, got {reader.fieldnames}"
        )
    for row in reader:
        if set(row) != set(CSV_COLUMNS) or any(row[column] is None for column in CSV_COLUMNS):
            raise RuntimeError(f"malformed trace report row: {row!r}")
        rows.append({**row, "value": parse_value(row["value"])})
    if not rows:
        raise RuntimeError("trace report returned no rows")
    missing = [section for section in REQUIRED_SECTIONS if not any(row["section"] == section for row in rows)]
    if missing:
        raise RuntimeError(f"trace report is missing required sections: {', '.join(missing)}")
    return rows


def metric_map(rows: list[dict[str, Any]]) -> dict[tuple[str, str], Any]:
    return {(row["section"], row["metric"]): row["value"] for row in rows}


def anomalies(rows: list[dict[str, Any]]) -> list[str]:
    metrics = metric_map(rows)
    result: list[str] = []

    checks = (
        (("front_buffer", "missing_payloads"), "missing front-buffer payloads"),
        (("front_buffer", "rejected_payloads"), "rejected front-buffer requests"),
        (("front_buffer", "superseded_payloads"), "superseded front-buffer payloads"),
        (("prediction", "final_retained_contours"), "stale retained prediction contours"),
        (("prediction", "final_prediction_state"), "prediction remains installed"),
        (("frames", "deadline_misses"), "FrameTimeline deadline misses"),
        (("frames", "dropped_app_frames"), "dropped app frames"),
    )
    for key, label in checks:
        value = metrics.get(key)
        if isinstance(value, (int, float)) and value > 0:
            result.append(f"{label}: {value}")

    if metrics.get(("allocation", "heap_profile_available")) == 0:
        result.append("allocation profiling unavailable: no heap-profile samples")

    for key in (("diagnostics", "target_process_present"), ("diagnostics", "ink_sign_slices_present")):
        if metrics.get(key) == 0:
            result.append(f"missing required {key[0]} metric: {key[1]}")
    return result


def format_markdown(trace: Path, file_size: int, rows: list[dict[str, Any]]) -> str:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        grouped.setdefault(row["section"], []).append(row)

    lines = [
        f"# InkSign trace report: `{trace.name}`",
        "",
        f"File size: `{file_size}` bytes (trace metric cross-check)",
        "",
    ]
    for section in sorted(grouped):
        if section == "diagnostics":
            continue
        lines.extend([f"## {section}", "", "| Metric | Scope | Value | Unit |", "|---|---|---:|---|"])
        for row in grouped[section]:
            lines.append(f"| {row['metric']} | {row['scope']} | {row['value']} | {row['unit']} |")
        lines.append("")

    warning_list = anomalies(rows)
    lines.append("## Status")
    lines.append("")
    if warning_list:
        lines.extend(f"- **Anomaly:** {warning}" for warning in warning_list)
    else:
        lines.append("- No configured anomalies detected.")
    return "\n".join(lines).rstrip() + "\n"


def format_json(trace: Path, file_size: int, rows: list[dict[str, Any]]) -> str:
    payload = {
        "trace": str(trace),
        "file_size_bytes": file_size,
        "file_size_cross_check": True,
        "metrics": rows,
        "anomalies": anomalies(rows),
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    args = parse_args()
    trace = args.trace.resolve()
    script_dir = Path(__file__).resolve().parent
    repo_dir = script_dir.parent
    processor = script_dir / "trace_processor"
    sql_file = repo_dir / "tools" / "trace-analysis.sql"

    if not trace.is_file():
        print(f"trace file does not exist: {trace}", file=sys.stderr)
        return 2
    if not processor.is_file():
        print(f"trace processor does not exist: {processor}", file=sys.stderr)
        return 2
    if not sql_file.is_file():
        print(f"SQL report does not exist: {sql_file}", file=sys.stderr)
        return 2

    try:
        rows = run_query(trace, sql_file, processor)
    except (OSError, RuntimeError, csv.Error) as error:
        print(f"trace analysis failed: {error}", file=sys.stderr)
        return 1

    file_size = trace.stat().st_size
    captured_size = next(
        row for row in rows
        if row["section"] == "trace" and row["metric"] == "captured_bytes"
    )
    if captured_size["value"] is None:
        captured_size["value"] = file_size
    elif captured_size["value"] != file_size:
        print(
            "trace analysis failed: SQL captured_bytes does not match the file size",
            file=sys.stderr,
        )
        return 1
    if args.format == "json":
        print(format_json(trace, file_size, rows), end="")
    else:
        print(format_markdown(trace, file_size, rows), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
