#!/usr/bin/env python3
"""Generate a markdown timing report of CI phase durations.

Reads timing entries written by create-cluster.sh and deploy-platform.sh
when NEBARI_TIMING_REPORT=true, formats a markdown table, and appends to
$GITHUB_STEP_SUMMARY (or stdout if unset).

TSV format: label<TAB>start_epoch_ms<TAB>end_epoch_ms
"""

import os
import sys


def fmt_duration(ms: int) -> str:
    if ms >= 60_000:
        m, s = divmod(ms // 1000, 60)
        return f"{m}m {s}s"
    if ms >= 1_000:
        return f"{ms / 1000:.1f}s"
    return f"{ms}ms"


def main() -> None:
    cluster_name = os.environ.get("CLUSTER_NAME", "nebari-test")
    timing_file = f"/tmp/nebari-timing-{cluster_name}.tsv"

    if not os.path.exists(timing_file):
        print(f"No timing file at {timing_file} — nothing to report.")
        return

    entries: list[tuple[str, int]] = []
    with open(timing_file) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) == 3:
                label, start_ms, end_ms = parts
                entries.append((label, int(end_ms) - int(start_ms)))

    if not entries:
        print("Timing file is empty — nothing to report.")
        return

    lines = [
        "## CI Timing Report",
        "",
        "| Phase | Duration |",
        "|---|---|",
    ]
    total_ms = 0
    for label, duration_ms in entries:
        total_ms += duration_ms
        lines.append(f"| {label} | {fmt_duration(duration_ms)} |")
    lines.append(f"| **Total instrumented** | **{fmt_duration(total_ms)}** |")
    lines.append("")

    output = "\n".join(lines) + "\n"
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as fh:
            fh.write(output)
        print(
            f"Wrote timing report to $GITHUB_STEP_SUMMARY ({len(entries)} phases)"
        )
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
