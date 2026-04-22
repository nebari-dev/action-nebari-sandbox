#!/usr/bin/env python3
"""Generate a markdown summary of cluster resource usage.

Waits for ArgoCD Applications to reach Healthy/Synced, then reads pod and node
info from the active kube context, formats a markdown table of CPU/memory
requests and limits per pod plus node allocatable capacity, and appends it to
$GITHUB_STEP_SUMMARY (or stdout if unset).

Resource accounting follows Kubernetes' effective-request rule:
    effective_request = max(max(initContainers), sum(containers))
because init containers run sequentially before the regular ones.

Pods in terminal phases (Succeeded/Failed) are excluded from totals — they
no longer consume resources — but listed separately at the bottom for
visibility.

Knobs (env):
- RESOURCE_SUMMARY_WAIT_TIMEOUT_S  default 600 — max seconds to wait for
                                   ArgoCD apps to settle before snapshotting
- RESOURCE_SUMMARY_POLL_INTERVAL_S default 10  — poll cadence while waiting
"""

import json
import os
import subprocess
import sys
import time


def cpu_to_millis(value):
    if not value:
        return 0
    s = str(value)
    if s.endswith("m"):
        return int(s[:-1])
    return int(float(s) * 1000)


def mem_to_mib(value):
    if not value:
        return 0.0
    s = str(value)
    units = {
        "Ki": 1024,
        "Mi": 1024 ** 2,
        "Gi": 1024 ** 3,
        "Ti": 1024 ** 4,
        "K": 1000,
        "M": 1000 ** 2,
        "G": 1000 ** 3,
        "T": 1000 ** 4,
    }
    for suffix, factor in units.items():
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * factor / (1024 ** 2)
    return float(s) / (1024 ** 2)


def fmt_cpu(millis):
    if millis == 0:
        return "—"
    if millis >= 1000:
        return f"{millis / 1000:g}"
    return f"{millis}m"


def fmt_mem(mib):
    if mib == 0:
        return "—"
    if mib < 1:
        return "<1Mi"
    if mib >= 1024:
        return f"{mib / 1024:g}Gi"
    return f"{int(mib)}Mi"


def kubectl_json(*args):
    """Run kubectl with -o json and decode. Exits 1 on failure with stderr."""
    try:
        out = subprocess.check_output(
            ["kubectl", *args, "-o", "json"], stderr=subprocess.PIPE
        )
    except subprocess.CalledProcessError as e:
        sys.stderr.write(
            f"kubectl {' '.join(args)} failed: {e.stderr.decode().strip()}\n"
        )
        sys.exit(1)
    except FileNotFoundError:
        sys.stderr.write("kubectl not found in PATH\n")
        sys.exit(1)
    return json.loads(out)


def _try_kubectl_json(*args):
    """Like kubectl_json but returns None on failure (for polling loops)."""
    try:
        out = subprocess.check_output(
            ["kubectl", *args, "-o", "json"], stderr=subprocess.PIPE
        )
        return json.loads(out)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def wait_for_argocd_apps(timeout_s, poll_interval_s):
    """Poll until every ArgoCD Application is Healthy and Synced, or timeout.

    On timeout, emits a GitHub Actions warning and returns; the caller
    continues with whatever state exists. We don't hard-fail because a
    partial snapshot is still useful, and the action's own await steps
    will catch real deployment failures elsewhere.
    """
    deadline = time.time() + timeout_s
    last_status_line = ""
    while time.time() < deadline:
        result = _try_kubectl_json("get", "applications.argoproj.io", "-A")
        if result is None:
            # ArgoCD CRDs not installed yet, or kubectl transient error.
            sys.stderr.write("  waiting for ArgoCD CRDs...\n")
            time.sleep(poll_interval_s)
            continue

        apps = result.get("items", [])
        if not apps:
            sys.stderr.write("  no ArgoCD Applications created yet...\n")
            time.sleep(poll_interval_s)
            continue

        statuses = [
            (
                a["metadata"]["name"],
                a.get("status", {}).get("health", {}).get("status", "?"),
                a.get("status", {}).get("sync", {}).get("status", "?"),
            )
            for a in apps
        ]
        unsettled = [(n, h, s) for n, h, s in statuses if h != "Healthy" or s != "Synced"]

        if not unsettled:
            print(f"All {len(apps)} ArgoCD Applications are Healthy and Synced")
            return

        line = ", ".join(f"{n}({h}/{s})" for n, h, s in unsettled)
        if line != last_status_line:
            sys.stderr.write(f"  waiting on: {line}\n")
            last_status_line = line
        time.sleep(poll_interval_s)

    sys.stderr.write(
        f"::warning::Timed out after {timeout_s}s waiting for ArgoCD Applications "
        f"to settle. Snapshot may be incomplete.\n"
    )


def pod_resources(pod):
    """Return [cpu_req_m, cpu_lim_m, mem_req_mib, mem_lim_mib] for a pod.

    Implements k8s scheduling math: effective request per resource is
    max(max(initContainers), sum(containers)). Init containers run
    sequentially before the regular ones, so the pod's claim is whichever
    is larger at any point.
    """
    init = pod["spec"].get("initContainers") or []
    main = pod["spec"].get("containers") or []

    init_max = [0, 0, 0.0, 0.0]
    for c in init:
        res = c.get("resources", {}) or {}
        per = [
            cpu_to_millis(res.get("requests", {}).get("cpu")),
            cpu_to_millis(res.get("limits", {}).get("cpu")),
            mem_to_mib(res.get("requests", {}).get("memory")),
            mem_to_mib(res.get("limits", {}).get("memory")),
        ]
        init_max = [max(a, b) for a, b in zip(init_max, per)]

    main_sum = [0, 0, 0.0, 0.0]
    for c in main:
        res = c.get("resources", {}) or {}
        main_sum[0] += cpu_to_millis(res.get("requests", {}).get("cpu"))
        main_sum[1] += cpu_to_millis(res.get("limits", {}).get("cpu"))
        main_sum[2] += mem_to_mib(res.get("requests", {}).get("memory"))
        main_sum[3] += mem_to_mib(res.get("limits", {}).get("memory"))

    return [max(i, m) for i, m in zip(init_max, main_sum)]


def main():
    timeout_s = int(os.environ.get("RESOURCE_SUMMARY_WAIT_TIMEOUT_S", "600"))
    poll_interval_s = int(os.environ.get("RESOURCE_SUMMARY_POLL_INTERVAL_S", "10"))

    print(f"Waiting up to {timeout_s}s for ArgoCD Applications to settle...")
    wait_for_argocd_apps(timeout_s, poll_interval_s)

    pods = kubectl_json("get", "pods", "-A")["items"]
    nodes = kubectl_json("get", "nodes")["items"]

    active = []
    completed = []
    totals = [0, 0, 0.0, 0.0]
    for pod in pods:
        ns = pod["metadata"]["namespace"]
        name = pod["metadata"]["name"]
        phase = pod.get("status", {}).get("phase", "Unknown")
        per = pod_resources(pod)
        if phase in ("Succeeded", "Failed"):
            completed.append((ns, name, phase, *per))
        else:
            active.append((ns, name, *per))
            for i in range(4):
                totals[i] += per[i]

    active.sort(key=lambda r: (r[0], r[1]))
    completed.sort(key=lambda r: (r[0], r[1]))

    lines = [
        "## Foundational Workload Resource Summary",
        "",
        "### Node Capacity (Allocatable)",
        "",
        "| Node | CPU | Memory |",
        "|------|-----|--------|",
    ]
    for n in nodes:
        nname = n["metadata"]["name"]
        alloc = n["status"]["allocatable"]
        lines.append(f"| `{nname}` | {alloc['cpu']} | {alloc['memory']} |")

    lines += [
        "",
        "### Active Pods (effective request: max(max(init), sum(main)))",
        "",
        "| Namespace | Pod | CPU Request | CPU Limit | Mem Request | Mem Limit |",
        "|-----------|-----|-------------|-----------|-------------|-----------|",
    ]
    for ns, name, cr, cl, mr, ml in active:
        lines.append(
            f"| {ns} | `{name}` | {fmt_cpu(cr)} | {fmt_cpu(cl)} | {fmt_mem(mr)} | {fmt_mem(ml)} |"
        )
    lines.append(
        f"| **Total** | | **{fmt_cpu(totals[0])}** | **{fmt_cpu(totals[1])}** "
        f"| **{fmt_mem(totals[2])}** | **{fmt_mem(totals[3])}** |"
    )

    if completed:
        lines += [
            "",
            "### Completed Pods (excluded from totals)",
            "",
            "| Namespace | Pod | Phase | CPU Request | Mem Request |",
            "|-----------|-----|-------|-------------|-------------|",
        ]
        for ns, name, phase, cr, _cl, mr, _ml in completed:
            lines.append(
                f"| {ns} | `{name}` | {phase} | {fmt_cpu(cr)} | {fmt_mem(mr)} |"
            )
    lines.append("")

    output = "\n".join(lines) + "\n"
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(output)
        print(
            f"Wrote resource summary to $GITHUB_STEP_SUMMARY "
            f"({len(active)} active, {len(completed)} completed pods)"
        )
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
