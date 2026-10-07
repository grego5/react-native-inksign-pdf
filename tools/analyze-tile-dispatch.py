"""Summarize the opt-in Android tile benchmark's monotonic timestamps."""

import argparse
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def ms(nanoseconds):
    return nanoseconds / 1_000_000


def median(values):
    return statistics.median(values) if values else None


def number(value):
    return f"{value:.3f}" if value is not None else "—"


def summarize(report):
    groups = defaultdict(list)
    for sample in report["samples"]:
        if sample["iteration"] > 0:
            groups[sample["workload"], sample["phase"]].append(sample)
    lines = [
        "# Android tile-dispatch measurement",
        "",
        f"Device: {report['device']}, Android API {report['sdk']}; {report['build']}.",
        f"Viewport: {report['viewportWidth']} × {report['viewportHeight']} px; density {report['density']}.",
        "",
        report["notes"],
        "",
        "Each group contains five measured runs. Latencies below are medians.",
        "Warm cache means the identical stationary viewport after prefetch drains.",
        "Pan is 121 scheduled positions, 16 ms apart, with reversal halfway through.",
        "",
        "| PDF / phase | First detail draw, ms | Full coverage, ms | Coverage after motion, ms | Renders / discarded |",
        "|---|---:|---:|---:|---:|",
    ]
    details = []
    for (workload, phase), samples in groups.items():
        renders = [record for sample in samples for record in sample["renders"]]
        first = [ms(s["firstDrawNs"] - s["startNs"]) for s in samples]
        coverage = [ms(s["coveredNs"] - s["startNs"]) for s in samples]
        after_motion = [ms(s["coveredNs"] - s["motionEndNs"]) for s in samples]
        discarded = sum(bool(r["discarded"]) for r in renders)
        lines.append(
            f"| {workload} / {phase} | {number(median(first))} | {number(median(coverage))} | "
            f"{number(median(after_motion)) if phase == 'pan-reverse' else '—'} | {len(renders)} / {discarded} |"
        )
        render_times = [ms(r["renderEndNs"] - r["renderStartNs"]) for r in renders]
        queues = [ms(r["workerStartNs"] - r["submitNs"]) for r in renders]
        admissions = [ms(r["acceptedNs"] - r["renderEndNs"]) for r in renders if r["acceptedNs"]]
        gaps, ui_gaps = [], []
        visible_render_totals, visible_gap_totals = [], []
        for sample in samples:
            ordered = sorted(sample["renders"], key=lambda r: r["renderStartNs"])
            visible_render_totals.append(sum(ms(r["renderEndNs"] - r["renderStartNs"]) for r in ordered if r["priority"] == 0))
            visible_gap = 0
            for previous, following in zip(ordered, ordered[1:]):
                # A new viewport can submit work after an intentionally idle interval.
                if following["submissionCause"] != "continuation":
                    continue
                gap = ms(following["renderStartNs"] - previous["renderEndNs"])
                gaps.append(gap)
                ui_gaps.append(ms(following["submitNs"] - previous["renderEndNs"]))
                if previous["priority"] == 0 and following["priority"] == 0:
                    visible_gap += gap
            visible_gap_totals.append(visible_gap)
        details.extend([
            "",
            f"## {workload} / {phase}",
            "",
            f"- Coverage range: {min(coverage):.3f}–{max(coverage):.3f} ms.",
            f"- Per-tile render median: {number(median(render_times))} ms; includes allocation, JNI, and PDFium.",
            f"- Continuation gap median: {number(median(gaps))} ms; excludes viewport-triggered submissions.",
            f"- Render-end → next submission median: {number(median(ui_gaps))} ms.",
            f"- Submission → worker start median: {number(median(queues))} ms.",
            f"- Render-end → UI admission observation median: {number(median(admissions))} ms.",
            f"- Visible render total per run median: {number(median(visible_render_totals))} ms.",
            f"- Gaps between consecutive visible renders per run median: {number(median(visible_gap_totals))} ms.",
            f"- Maximum scripted-step lateness: {max(s['maxStepLatenessMs'] for s in samples)} ms.",
            f"- Incomplete / total drawn frames: {sum(s['incompleteDraws'] for s in samples)} / {sum(s['draws'] for s in samples)}.",
        ])
    memory = defaultdict(list)
    for sample in report.get("memorySamples", []):
        if sample["iteration"] > 0:
            memory[sample["workload"]].append(sample)
    if memory:
        details.extend([
            "", "## Idle memory snapshots", "",
            "Medians after cold prefetch drains, relative to before opening the session.",
            "Native allocation includes tile pixels and PDFium allocations. PSS is whole-process resident memory.",
            "These snapshots do not measure peak render memory.", "",
            "| PDF | Native allocation increase, MiB | PSS increase, MiB | Tile cache, MiB | Native increase after close, MiB |",
            "|---|---:|---:|---:|---:|",
        ])
        for workload, samples in memory.items():
            native = median([(s["afterColdDrain"]["nativeHeapBytes"] - s["beforeOpen"]["nativeHeapBytes"]) / 2**20 for s in samples])
            pss = median([(s["afterColdDrain"]["pssKb"] - s["beforeOpen"]["pssKb"]) / 1024 for s in samples])
            tiles = median([s["coldTileBytes"] / 2**20 for s in samples])
            closed = median([(s["afterClose"]["nativeHeapBytes"] - s["beforeOpen"]["nativeHeapBytes"]) / 2**20 for s in samples])
            details.append(f"| {workload} | {number(native)} | {number(pss)} | {number(tiles)} | {number(closed)} |")
    return "\n".join(lines + details) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    print(summarize(json.loads(args.report.read_text(encoding="utf-8"))), end="")


if __name__ == "__main__":
    main()
