#!/usr/bin/env python3
"""Generate a markdown timing report of CI phase durations.

Reads timing entries written by create-cluster.sh, deploy-platform.sh, and
collect-deploy-timings.py when NEBARI_TIMING_REPORT=true. Renders a markdown
report with three sections — phases, image pulls, ArgoCD app sync — and
appends to $GITHUB_STEP_SUMMARY (or stdout if unset).

TSV format: <label>\\t<start_epoch_ms>\\t<end_epoch_ms>

Label conventions:
  - `image-pull: <ns>/<image>`     — per-image pull from kubelet events
  - `argocd-sync: <app>`           — per-Application sync from status.operationState
  - anything else                  — high-level phase (e.g. "nic deploy (total)")
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

_IMAGE_PULL_PREFIX = "image-pull: "
_ARGOCD_SYNC_PREFIX = "argocd-sync: "


def fmt_duration(ms: int) -> str:
    if ms >= 60_000:
        m, s = divmod(ms // 1000, 60)
        return f"{m}m {s}s"
    if ms >= 1_000:
        return f"{ms / 1000:.1f}s"
    return f"{ms}ms"


def _strip_prefix(label: str, prefix: str) -> str:
    return label[len(prefix):] if label.startswith(prefix) else label


def _render_phase_table(rows: list[tuple[str, int]]) -> list[str]:
    lines = [
        "### Phases",
        "",
        "| Phase | Duration |",
        "|---|---|",
    ]
    for label, duration in rows:
        lines.append(f"| {label} | {fmt_duration(duration)} |")
    total = sum(d for _, d in rows)
    lines.append(f"| **Total** | **{fmt_duration(total)}** |")
    lines.append("")
    return lines


def _render_image_pulls(rows: list[tuple[str, int]]) -> list[str]:
    lines = [
        "### Image pulls (per pod, sorted by duration)",
        "",
        "| Image | Namespace | Pull duration |",
        "|---|---|---|",
    ]
    # Each label is "image-pull: <ns>/<image>". Split back out for the table.
    parsed: list[tuple[str, str, int]] = []
    for label, duration in rows:
        body = _strip_prefix(label, _IMAGE_PULL_PREFIX)
        ns, _, image = body.partition("/")
        parsed.append((image or body, ns, duration))
    parsed.sort(key=lambda r: r[2], reverse=True)
    for image, ns, duration in parsed:
        lines.append(f"| `{image}` | {ns} | {fmt_duration(duration)} |")
    lines.append("")
    lines.append(
        f"> {len(parsed)} image-pull events from kubelet. "
        "Each row is one pod's pull of one image inside a k3s node."
    )
    lines.append("")
    return lines


def _render_argocd_syncs(rows: list[tuple[str, int]]) -> list[str]:
    lines = [
        "### ArgoCD app sync convergence (sorted by duration)",
        "",
        "| Application | Sync duration |",
        "|---|---|",
    ]
    parsed = [(_strip_prefix(label, _ARGOCD_SYNC_PREFIX), duration) for label, duration in rows]
    parsed.sort(key=lambda r: r[1], reverse=True)
    for app, duration in parsed:
        lines.append(f"| {app} | {fmt_duration(duration)} |")
    lines.append("")
    lines.append(
        f"> {len(parsed)} Applications. Duration is "
        "`status.operationState.finishedAt - startedAt` for the most recent sync."
    )
    lines.append("")
    return lines


def main() -> None:
    cluster_name = os.environ.get("CLUSTER_NAME", "nebari-test")
    timing_file = Path(f"/tmp/nebari-timing-{cluster_name}.tsv")

    if not timing_file.exists():
        print(f"No timing file at {timing_file} - nothing to report.")
        return

    phases: list[tuple[str, int]] = []
    pulls: list[tuple[str, int]] = []
    syncs: list[tuple[str, int]] = []

    for raw in timing_file.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        label, start_ms, end_ms = parts
        duration = int(end_ms) - int(start_ms)
        if label.startswith(_IMAGE_PULL_PREFIX):
            pulls.append((label, duration))
        elif label.startswith(_ARGOCD_SYNC_PREFIX):
            syncs.append((label, duration))
        else:
            phases.append((label, duration))

    if not (phases or pulls or syncs):
        print("Timing file is empty - nothing to report.")
        return

    lines: list[str] = ["## CI Timing Report", ""]
    if phases:
        lines.extend(_render_phase_table(phases))
    if pulls:
        lines.extend(_render_image_pulls(pulls))
    if syncs:
        lines.extend(_render_argocd_syncs(syncs))

    output = "\n".join(lines)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as fh:
            fh.write(output)
        total = len(phases) + len(pulls) + len(syncs)
        print(
            f"Wrote timing report to $GITHUB_STEP_SUMMARY "
            f"({len(phases)} phases, {len(pulls)} pulls, {len(syncs)} syncs; {total} entries)"
        )
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
