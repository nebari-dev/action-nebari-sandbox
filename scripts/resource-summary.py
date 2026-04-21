#!/usr/bin/env python3
"""Generate a markdown summary of cluster resource usage.

Reads pod and node info from the active kube context, formats a markdown
table of CPU/memory requests and limits per pod plus node allocatable
capacity, and appends it to $GITHUB_STEP_SUMMARY (or stdout if unset).

Intended to run after the platform stack has been deployed and awaited,
so the output reflects steady-state resource consumption — useful for
tracking minimum-spec requirements as the foundational stack evolves.
"""

import json
import os
import subprocess
import sys


def cpu_to_millis(value):
    if not value:
        return 0
    s = str(value)
    if s.endswith("m"):
        return int(s[:-1])
    return int(float(s) * 1000)


def mem_to_mib(value):
    if not value:
        return 0
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
            return int(float(s[: -len(suffix)]) * factor / (1024 ** 2))
    return int(float(s) / (1024 ** 2))


def fmt_cpu(millis):
    if millis == 0:
        return "—"
    if millis >= 1000:
        return f"{millis / 1000:g}"
    return f"{millis}m"


def fmt_mem(mib):
    if mib == 0:
        return "—"
    if mib >= 1024:
        return f"{mib / 1024:g}Gi"
    return f"{mib}Mi"


def kubectl_json(*args):
    out = subprocess.check_output(["kubectl", *args, "-o", "json"])
    return json.loads(out)


def main():
    pods = kubectl_json("get", "pods", "-A")["items"]
    nodes = kubectl_json("get", "nodes")["items"]

    rows = []
    totals = [0, 0, 0, 0]  # cpu_req, cpu_lim, mem_req, mem_lim
    for pod in pods:
        ns = pod["metadata"]["namespace"]
        name = pod["metadata"]["name"]
        per = [0, 0, 0, 0]
        for c in pod["spec"].get("containers", []):
            res = c.get("resources", {})
            per[0] += cpu_to_millis(res.get("requests", {}).get("cpu"))
            per[1] += cpu_to_millis(res.get("limits", {}).get("cpu"))
            per[2] += mem_to_mib(res.get("requests", {}).get("memory"))
            per[3] += mem_to_mib(res.get("limits", {}).get("memory"))
        rows.append((ns, name, *per))
        for i in range(4):
            totals[i] += per[i]

    rows.sort(key=lambda r: (r[0], r[1]))

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
        "### Pod Resources (sum across containers per pod)",
        "",
        "| Namespace | Pod | CPU Request | CPU Limit | Mem Request | Mem Limit |",
        "|-----------|-----|-------------|-----------|-------------|-----------|",
    ]
    for ns, name, cr, cl, mr, ml in rows:
        lines.append(
            f"| {ns} | `{name}` | {fmt_cpu(cr)} | {fmt_cpu(cl)} | {fmt_mem(mr)} | {fmt_mem(ml)} |"
        )
    lines.append(
        f"| **Total** | | **{fmt_cpu(totals[0])}** | **{fmt_cpu(totals[1])}** "
        f"| **{fmt_mem(totals[2])}** | **{fmt_mem(totals[3])}** |"
    )
    lines.append("")

    output = "\n".join(lines) + "\n"
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(output)
        print(f"Wrote resource summary to $GITHUB_STEP_SUMMARY ({len(rows)} pods)")
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
