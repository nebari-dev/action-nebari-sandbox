#!/usr/bin/env python3
"""Generate a markdown timing report of CI phase durations.

Reads timing entries written by create-cluster.sh and deploy-platform.sh
when NEBARI_TIMING_REPORT=true, formats a markdown table, and appends to
$GITHUB_STEP_SUMMARY (or stdout if unset).

TSV format: label<TAB>start_epoch_ms<TAB>end_epoch_ms

Entries prefixed with "first container ready:" are treated as a parallel
group — all share the same start_ms baseline (nic deploy start) and their
durations overlap rather than being additive. The summary for this group
uses mode (most frequent 5s bucket, i.e. the typical namespace startup time)
and max (the actual wall-clock bottleneck), not sum.
"""

import os
import sys
from collections import Counter

# Label prefix that marks entries in the parallel container-start group.
_PARALLEL_PREFIX = "first container ready:"
# Bucket size for mode calculation (5 s in ms).
_MODE_BUCKET_MS = 5_000


def fmt_duration(ms: int) -> str:
    if ms >= 60_000:
        m, s = divmod(ms // 1000, 60)
        return f"{m}m {s}s"
    if ms >= 1_000:
        return f"{ms / 1000:.1f}s"
    return f"{ms}ms"


def _mode_ms(durations: list[int]) -> int:
    """Return the centre of the most frequent 5 s bucket."""
    buckets = [round(d / _MODE_BUCKET_MS) * _MODE_BUCKET_MS for d in durations]
    return Counter(buckets).most_common(1)[0][0]


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

    sequential = [(l, d) for l, d in entries if not l.startswith(_PARALLEL_PREFIX)]
    parallel   = [(l, d) for l, d in entries if l.startswith(_PARALLEL_PREFIX)]

    lines = [
        "## CI Timing Report",
        "",
        "| Phase | Duration |",
        "|---|---|",
    ]
    for label, duration_ms in entries:
        prefix = "↳ " if label.startswith(_PARALLEL_PREFIX) else ""
        lines.append(f"| {prefix}{label} | {fmt_duration(duration_ms)} |")

    seq_total_ms = sum(d for _, d in sequential)
    lines.append(f"| **Sequential total** | **{fmt_duration(seq_total_ms)}** |")

    if parallel:
        parallel_durations = [d for _, d in parallel]
        mode_ms = _mode_ms(parallel_durations)
        max_ms  = max(parallel_durations)
        lines.append(
            f"| **↳ Parallel group — mode (typical namespace)** | **{fmt_duration(mode_ms)}** |"
        )
        lines.append(
            f"| **↳ Parallel group — max (bottleneck)** | **{fmt_duration(max_ms)}** |"
        )
        lines.append("")
        lines.append(
            f"> ↳ *{len(parallel)} namespaces pull images concurrently. "
            "Their durations are measured from the same baseline (nic deploy start) "
            "and are **not additive** — the wall-clock cost is the max, "
            "and the mode reflects the most common startup time across namespaces.*"
        )

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
