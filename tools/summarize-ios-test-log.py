#!/usr/bin/env python3
"""Print actionable Xcode diagnostics while leaving the source log untouched."""

from __future__ import annotations

import re
import sys
from pathlib import Path


DIAGNOSTIC = re.compile(
    r"(?:\berror:|\bwarning:|precondition failed|assertion failed|"
    r"unable to find utility|TEST (?:SUCCEEDED|FAILED)|BUILD (?:SUCCEEDED|FAILED)|"
    r"Executed \d+ tests|Test Case .* failed|Test Suite .* failed)",
    re.IGNORECASE,
)
SIMULATOR_NOISE = (
    "CHHapticPattern.mm:487",
    "[coreml] Failed to get the home directory when checking model path.",
)
MAX_LINES = 100
MAX_LINE_LENGTH = 1_200


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} XCODEBUILD_LOG", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1])
    selected: list[tuple[int, str]] = []
    with log_path.open(encoding="utf-8", errors="replace") as log:
        for line_number, raw_line in enumerate(log, start=1):
            line = raw_line.replace("\x00", "").rstrip()
            if any(noise in line for noise in SIMULATOR_NOISE):
                continue
            if DIAGNOSTIC.search(line):
                selected.append((line_number, line[:MAX_LINE_LENGTH]))

    print(f"Relevant Xcode diagnostics from {log_path}:")
    if not selected:
        print("No matching build or test diagnostics. The complete log is preserved.")
        return 0

    if len(selected) > MAX_LINES:
        omitted = len(selected) - MAX_LINES
        selected = selected[: MAX_LINES // 2] + selected[-(MAX_LINES // 2) :]
        print(f"Showing first and last {MAX_LINES // 2} entries; omitted {omitted} entries.")

    for line_number, line in selected:
        print(f"{line_number}: {line}")
    print("The complete log and xcresult bundle remain available for inspection.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
