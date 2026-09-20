#!/usr/bin/env python3
"""Compare two JSON reports produced by analyze-trace.py."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


ROW_KEYS = frozenset(("section", "metric", "scope", "value", "unit"))
SERIALIZED_METRIC_NAMES = frozenset(("serialized_frame_bytes", "serialized_frame_count"))
GEOMETRY_KEY = ("native_timing", "average", "cpp_geometry")
MetricKey = tuple[str, str, str]


class ReportError(ValueError):
    """An input report is not a compatible analyzer JSON report."""


def nonnegative_float(raw: str) -> float:
    try:
        value = float(raw)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not a number: {raw!r}") from error
    if not math.isfinite(value) or value < 0:
        raise argparse.ArgumentTypeError("threshold must be a finite nonnegative number")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="baseline analyzer JSON report")
    parser.add_argument("current", type=Path, help="current analyzer JSON report")
    parser.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="report format (default: markdown)",
    )
    parser.add_argument(
        "--max-geometry-regression-ms",
        type=nonnegative_float,
        metavar="MS",
        help="fail when current average cpp geometry exceeds baseline by more than MS",
    )
    parser.add_argument(
        "--require-same-serialized-bytes",
        action="store_true",
        help="fail when comparable serialized frame byte metrics differ",
    )
    return parser.parse_args()


def metric_key(row: dict[str, Any]) -> MetricKey:
    return (row["section"], row["metric"], row["scope"])


def validate_value(value: Any, row_number: int) -> None:
    if value is None or isinstance(value, str):
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReportError(f"invalid metric value at row {row_number}: {value!r}")
    if not math.isfinite(float(value)):
        raise ReportError(f"non-finite metric value at row {row_number}")


def load_report(path: Path) -> tuple[dict[str, Any], dict[MetricKey, dict[str, Any]]]:
    if not path.is_file():
        raise ReportError(f"report file does not exist: {path.resolve()}")
    try:
        with path.open("r", encoding="utf-8") as report_file:
            payload = json.load(report_file)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReportError(f"cannot read JSON report {path}: {error}") from error

    if not isinstance(payload, dict):
        raise ReportError(f"JSON report must contain an object: {path}")
    required_envelope = {
        "trace",
        "file_size_bytes",
        "file_size_cross_check",
        "metrics",
        "anomalies",
    }
    missing_envelope = sorted(required_envelope - payload.keys())
    if missing_envelope:
        raise ReportError(f"{path}: missing envelope fields: {', '.join(missing_envelope)}")
    if not isinstance(payload["trace"], str) or not payload["trace"]:
        raise ReportError(f"{path}: envelope trace must be a nonempty string")
    if (
        isinstance(payload["file_size_bytes"], bool)
        or not isinstance(payload["file_size_bytes"], int)
        or payload["file_size_bytes"] < 0
    ):
        raise ReportError(f"{path}: envelope file_size_bytes must be a nonnegative integer")
    if not isinstance(payload["file_size_cross_check"], bool):
        raise ReportError(f"{path}: envelope file_size_cross_check must be boolean")
    if not isinstance(payload["metrics"], list) or not payload["metrics"]:
        raise ReportError(f"{path}: envelope metrics must be a nonempty array")
    if not isinstance(payload["anomalies"], list) or not all(
        isinstance(anomaly, str) for anomaly in payload["anomalies"]
    ):
        raise ReportError(f"{path}: envelope anomalies must be an array of strings")

    rows: dict[MetricKey, dict[str, Any]] = {}
    for row_number, row in enumerate(payload["metrics"], start=1):
        if not isinstance(row, dict) or frozenset(row) != ROW_KEYS:
            raise ReportError(
                f"{path}: malformed metric row {row_number}; expected fields {sorted(ROW_KEYS)}"
            )
        for field in ("section", "metric", "scope", "unit"):
            if not isinstance(row[field], str) or not row[field]:
                raise ReportError(f"{path}: metric row {row_number} has invalid {field}")
        validate_value(row["value"], row_number)
        key = metric_key(row)
        if key in rows:
            raise ReportError(f"{path}: duplicate metric key: {' / '.join(key)}")
        rows[key] = row
    return payload, rows


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def format_value(value: Any) -> str:
    if value is None:
        return "unavailable"
    if isinstance(value, float):
        return format(value, ".15g")
    return str(value)


def format_json_value(value: Any) -> Any:
    return value


def percentage_delta(baseline: Any, delta: Any) -> float | None:
    if not is_number(baseline) or not is_number(delta) or baseline == 0:
        return None
    return 100.0 * delta / baseline


def compare_metrics(
    baseline_rows: dict[MetricKey, dict[str, Any]],
    current_rows: dict[MetricKey, dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    common_keys = sorted(baseline_rows.keys() & current_rows.keys())
    for key in common_keys:
        baseline_unit = baseline_rows[key]["unit"]
        current_unit = current_rows[key]["unit"]
        if baseline_unit != current_unit:
            raise ReportError(
                f"incompatible unit for {' / '.join(key)}: "
                f"baseline={baseline_unit!r}, current={current_unit!r}"
            )

    deltas: list[dict[str, Any]] = []
    for key in common_keys:
        baseline = baseline_rows[key]["value"]
        current = current_rows[key]["value"]
        delta = current - baseline if is_number(baseline) and is_number(current) else None
        deltas.append(
            {
                "section": key[0],
                "metric": key[1],
                "scope": key[2],
                "unit": baseline_rows[key]["unit"],
                "baseline": format_json_value(baseline),
                "current": format_json_value(current),
                "absolute_delta": delta,
                "percentage_delta": percentage_delta(baseline, delta),
            }
        )

    missing: list[dict[str, str]] = []
    for key in sorted(baseline_rows.keys() - current_rows.keys()):
        missing.append({"section": key[0], "metric": key[1], "scope": key[2], "missing_from": "current"})
    for key in sorted(current_rows.keys() - baseline_rows.keys()):
        missing.append({"section": key[0], "metric": key[1], "scope": key[2], "missing_from": "baseline"})
    return deltas, missing


def gate_result(
    name: str,
    passed: bool | None,
    detail: str,
) -> dict[str, Any]:
    return {"name": name, "status": "PASS" if passed is True else "FAIL" if passed is False else "SKIP", "detail": detail}


def evaluate_gates(
    baseline_rows: dict[MetricKey, dict[str, Any]],
    current_rows: dict[MetricKey, dict[str, Any]],
    geometry_limit: float | None,
    require_serialized_bytes: bool,
) -> list[dict[str, Any]]:
    gates: list[dict[str, Any]] = []
    if geometry_limit is not None:
        baseline = baseline_rows.get(GEOMETRY_KEY)
        current = current_rows.get(GEOMETRY_KEY)
        if baseline is None or current is None:
            gates.append(gate_result("max_geometry_regression_ms", None, "target metric missing"))
        elif not is_number(baseline["value"]) or not is_number(current["value"]):
            gates.append(gate_result("max_geometry_regression_ms", None, "target metric unavailable"))
        else:
            regression = current["value"] - baseline["value"]
            passed = regression <= geometry_limit
            gates.append(
                gate_result(
                    "max_geometry_regression_ms",
                    passed,
                    f"regression={format_value(regression)} ms, limit={format_value(geometry_limit)} ms",
                )
            )

    if require_serialized_bytes:
        keys = sorted(
            key
            for key in baseline_rows.keys() & current_rows.keys()
            if key[0] == "native_timing" and key[1] in SERIALIZED_METRIC_NAMES
        )
        if not keys:
            gates.append(gate_result("require_same_serialized_bytes", None, "serialized-byte metric missing"))
        else:
            unequal: list[str] = []
            unavailable: list[str] = []
            for key in keys:
                baseline = baseline_rows[key]["value"]
                current = current_rows[key]["value"]
                if not is_number(baseline) or not is_number(current):
                    unavailable.append(" / ".join(key))
                elif baseline != current:
                    unequal.append(
                        f"{' / '.join(key)} baseline={format_value(baseline)} current={format_value(current)}"
                    )
            if unequal:
                gates.append(gate_result("require_same_serialized_bytes", False, "; ".join(unequal)))
            elif unavailable:
                gates.append(gate_result("require_same_serialized_bytes", None, "unavailable: " + ", ".join(unavailable)))
            else:
                gates.append(gate_result("require_same_serialized_bytes", True, f"checked {len(keys)} metric(s)"))
    return gates


def comparison_payload(
    baseline: Path,
    current: Path,
    baseline_payload: dict[str, Any],
    current_payload: dict[str, Any],
    deltas: list[dict[str, Any]],
    missing: list[dict[str, str]],
    gates: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "baseline": str(baseline.resolve()),
        "current": str(current.resolve()),
        "baseline_trace": baseline_payload["trace"],
        "current_trace": current_payload["trace"],
        "metrics": deltas,
        "missing_metrics": missing,
        "gates": gates,
    }


def format_markdown(payload: dict[str, Any]) -> str:
    lines = [
        "# InkSign trace comparison",
        "",
        f"Baseline: `{payload['baseline']}`  ",
        f"Current: `{payload['current']}`",
        "",
        "## Metrics",
        "",
        "| Section | Metric | Scope | Unit | Baseline | Current | Absolute delta | Delta % |",
        "|---|---|---|---|---:|---:|---:|---:|",
    ]
    for row in payload["metrics"]:
        percentage = row["percentage_delta"]
        percentage_text = "unavailable" if percentage is None else format_value(percentage) + "%"
        lines.append(
            "| {section} | {metric} | {scope} | {unit} | {baseline} | {current} | {delta} | {percentage} |".format(
                section=row["section"],
                metric=row["metric"],
                scope=row["scope"],
                unit=row["unit"],
                baseline=format_value(row["baseline"]),
                current=format_value(row["current"]),
                delta=format_value(row["absolute_delta"]),
                percentage=percentage_text,
            )
        )
    lines.extend(("", "## Missing metrics", "", "| Section | Metric | Scope | Missing from |", "|---|---|---|---|"))
    if payload["missing_metrics"]:
        for row in payload["missing_metrics"]:
            lines.append("| {section} | {metric} | {scope} | {missing_from} |".format(**row))
    else:
        lines.append("| - | - | - | none |")
    lines.extend(("", "## Regression gates", ""))
    if payload["gates"]:
        for gate in payload["gates"]:
            lines.append(f"- **{gate['status']}** `{gate['name']}`: {gate['detail']}")
    else:
        lines.append("- No regression gates requested.")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        baseline_payload, baseline_rows = load_report(args.baseline)
        current_payload, current_rows = load_report(args.current)
        deltas, missing = compare_metrics(baseline_rows, current_rows)
        gates = evaluate_gates(
            baseline_rows,
            current_rows,
            args.max_geometry_regression_ms,
            args.require_same_serialized_bytes,
        )
    except (OSError, ReportError) as error:
        print(f"trace comparison failed: {error}", file=sys.stderr)
        return 1

    payload = comparison_payload(
        args.baseline,
        args.current,
        baseline_payload,
        current_payload,
        deltas,
        missing,
        gates,
    )
    if args.format == "json":
        print(json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True))
    else:
        print(format_markdown(payload), end="")
    return 1 if any(gate["status"] == "FAIL" for gate in gates) else 0


if __name__ == "__main__":
    raise SystemExit(main())
