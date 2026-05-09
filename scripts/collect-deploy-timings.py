#!/usr/bin/env python3
"""Collect post-deploy timing data from the live cluster into the timing TSV.

Invoked from deploy-platform.sh when NEBARI_TIMING_REPORT=true. Writes three
categories of entries:

- `nic-phase: <phase>` — parsed from NIC's structured JSON stdout log.
  NIC emits ISO-8601 timestamped JSON lines with `msg` phase markers. We pair
  start/end markers to compute per-phase NIC durations (config parse, gitops
  bootstrap, ArgoCD chart install, foundational install, etc.). Captures the
  NIC-internal breakdown asked for in #17 without requiring a NIC-side flag.

- `image-pull: <ns>/<image>` — parsed from `kubectl get events reason=Pulled`,
  one per Pulled event. Duration is taken from the kubelet message string
  ("Successfully pulled image X in N.Ns"); start/end are derived from the
  event timestamp minus that duration. Captures per-image pull cost inside
  k3s nodes.

- `argocd-sync: <app>` — parsed from `kubectl get application -n argocd`,
  one per Application's most recent sync. Uses
  `status.operationState.startedAt`/`finishedAt`. Captures ArgoCD sync
  convergence cost — distinct from image pull and from container startup.

TSV format (matches existing entries from deploy-platform.sh):
    <label>\\t<start_epoch_ms>\\t<end_epoch_ms>

Usage:
    python3 collect-deploy-timings.py <timing_file> <nic_start_ms> <nic_log_file>
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


_PULL_IMAGE = re.compile(r'pulled image "([^"]+)"')
_PULL_DURATION = re.compile(r'\bin\s+(\d+(?:\.\d+)?)(ms|s|m)\b')
_UNIT_TO_MS = {"ms": 1, "s": 1000, "m": 60_000}

# NIC log phase pairs: (start_msg, end_msg, output_label).
# Pairs are matched by exact `msg` field equality on the JSON log lines NIC
# emits to stdout. First start/end after each other forms one phase entry.
_NIC_PHASE_PAIRS: list[tuple[str, str, str]] = [
    ("Initializing local GitOps directory",
     "Local GitOps directory bootstrapped successfully",
     "gitops bootstrap"),
    ("Installing Argo CD on cluster",
     "Argo CD installed successfully",
     "argocd install"),
    ("Installing foundational services",
     "Foundational services installed successfully",
     "foundational install"),
    ("Starting deployment",
     "Deployment completed successfully",
     "nic total (per logs)"),
]


def _parse_iso8601_ms(s: str) -> int | None:
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except (ValueError, AttributeError):
        return None


def _kubectl_json(args: list[str]) -> dict:
    """Run kubectl with -o json, return parsed dict or empty {items: []} on failure."""
    try:
        r = subprocess.run(
            ["kubectl", *args, "-o", "json"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        if r.returncode != 0:
            return {"items": []}
        return json.loads(r.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return {"items": []}


def collect_image_pulls(nic_start_ms: int) -> list[tuple[str, int, int]]:
    """Return [(label, start_ms, end_ms), ...] for each kubelet Pulled event."""
    events = _kubectl_json(
        ["get", "events", "-A", "--field-selector", "reason=Pulled"]
    ).get("items", []) or []
    rows: list[tuple[str, int, int]] = []
    for ev in events:
        ns = (ev.get("metadata") or {}).get("namespace", "?")
        msg = ev.get("note") or ev.get("message") or ""
        m_img = _PULL_IMAGE.search(msg)
        m_dur = _PULL_DURATION.search(msg)
        if not (m_img and m_dur):
            continue
        image = m_img.group(1)
        amount, unit = float(m_dur.group(1)), m_dur.group(2)
        duration_ms = int(amount * _UNIT_TO_MS.get(unit, 1000))
        ev_time = ev.get("eventTime") or ev.get("firstTimestamp")
        end_ms = _parse_iso8601_ms(ev_time) if ev_time else None
        if end_ms is None:
            # Fall back to nic_start as the anchor if event has no timestamp.
            start_ms = nic_start_ms
            end_ms = start_ms + duration_ms
        else:
            start_ms = end_ms - duration_ms
        rows.append((f"image-pull: {ns}/{image}", start_ms, end_ms))
    return rows


def collect_nic_phases(nic_log_path: Path) -> list[tuple[str, int, int]]:
    """Parse NIC's structured JSON log for phase-pair durations.

    NIC emits one JSON line per event to stdout, with `time` (ISO 8601),
    `level`, and `msg`. We walk the log in order; for each pair in
    _NIC_PHASE_PAIRS, we take the first occurrence of start_msg and the
    first occurrence of end_msg that follows it.
    """
    if not nic_log_path.exists():
        return []

    # (msg, time_ms) in chronological order
    entries: list[tuple[str, int]] = []
    for line in nic_log_path.read_text().splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        t_ms = _parse_iso8601_ms(obj.get("time", ""))
        msg = obj.get("msg", "")
        if t_ms is not None and msg:
            entries.append((msg, t_ms))

    rows: list[tuple[str, int, int]] = []
    for start_msg, end_msg, label in _NIC_PHASE_PAIRS:
        start_ms: int | None = None
        for msg, t in entries:
            if start_ms is None and msg == start_msg:
                start_ms = t
            elif start_ms is not None and msg == end_msg:
                rows.append((f"nic-phase: {label}", start_ms, t))
                break
    return rows


def collect_argocd_syncs() -> list[tuple[str, int, int]]:
    """Return [(label, start_ms, end_ms), ...] for each ArgoCD Application's most recent sync."""
    apps = _kubectl_json(
        ["get", "application", "-n", "argocd"]
    ).get("items", []) or []
    rows: list[tuple[str, int, int]] = []
    for app in apps:
        name = (app.get("metadata") or {}).get("name", "?")
        op = ((app.get("status") or {}).get("operationState") or {})
        start_ms = _parse_iso8601_ms(op.get("startedAt", ""))
        end_ms = _parse_iso8601_ms(op.get("finishedAt", ""))
        if start_ms is None or end_ms is None or end_ms < start_ms:
            continue
        rows.append((f"argocd-sync: {name}", start_ms, end_ms))
    return rows


def main() -> None:
    if len(sys.argv) != 4:
        print(
            f"usage: {sys.argv[0]} <timing_file> <nic_start_ms> <nic_log_file>",
            file=sys.stderr,
        )
        sys.exit(2)

    timing_path = Path(sys.argv[1])
    nic_start_ms = int(sys.argv[2])
    nic_log_path = Path(sys.argv[3])

    nic_phases = collect_nic_phases(nic_log_path)
    pulls = collect_image_pulls(nic_start_ms)
    syncs = collect_argocd_syncs()

    with timing_path.open("a") as fh:
        for label, start_ms, end_ms in nic_phases + pulls + syncs:
            fh.write(f"{label}\t{start_ms}\t{end_ms}\n")

    print(
        f"Collected {len(nic_phases)} nic-phase, {len(pulls)} image-pull, "
        f"and {len(syncs)} argocd-sync entries."
    )


if __name__ == "__main__":
    main()
