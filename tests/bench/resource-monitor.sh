#!/usr/bin/env bash
# Benchmark helper (draft): sample host + container resource usage during a
# deploy, then summarize peaks/averages. Used to compare how much a k3d (k3s in
# a container) vs a kind (full node container) platform deploy stresses the CI
# runner. Not part of the shipped action.
#
# Modes:
#   start          - spawn a detached background sampler (survives across steps)
#   stop <label>   - kill the sampler and append a markdown summary to
#                    $GITHUB_STEP_SUMMARY (and stdout)
#
# Runner assumption: 4 vCPU / 16 GB (GitHub-hosted ubuntu-24.04), so load1 is
# read relative to 4 cores.

set -uo pipefail

SAMPLES="${BENCH_SAMPLES:-/tmp/bench-samples.tsv}"
PIDFILE="${BENCH_PIDFILE:-/tmp/bench-monitor.pid}"
INTERVAL="${BENCH_INTERVAL:-3}"

_sampler() {
  echo "$$" > "${PIDFILE}"
  printf 'epoch\tmem_used_mb\tload1\tcontainers_mem_mb\n' > "${SAMPLES}"
  while true; do
    mem=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d",(t-a)/1024}' /proc/meminfo)
    load=$(awk '{print $1}' /proc/loadavg)
    # Sum running-container memory (MiB). docker MemUsage looks like
    # "512.3MiB / 15.61GiB"; $1 is the "used" value+unit.
    cmem=$(docker stats --no-stream --format '{{.MemUsage}}' 2>/dev/null | awk '
      { v=$1; unit=v; sub(/^[0-9.]+/,"",unit); sub(/[A-Za-z]+$/,"",v);
        if(unit=="GiB") v*=1024; else if(unit=="KiB") v/=1024; else if(unit=="B") v/=1048576;
        s+=v } END{ printf "%d", s+0 }')
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${mem}" "${load}" "${cmem:-0}" >> "${SAMPLES}"
    sleep "${INTERVAL}"
  done
}

case "${1:-}" in
  start)
    rm -f "${SAMPLES}" "${PIDFILE}"
    setsid nohup bash "$0" _loop >/tmp/bench-monitor.log 2>&1 </dev/null &
    sleep 1
    echo "resource monitor started (pid $(cat "${PIDFILE}" 2>/dev/null || echo '?'), every ${INTERVAL}s)"
    ;;
  _loop)
    _sampler
    ;;
  stop)
    label="${2:-deploy}"
    if [ -f "${PIDFILE}" ]; then kill "$(cat "${PIDFILE}")" 2>/dev/null || true; fi
    python3 - "${SAMPLES}" "${label}" <<'PY'
import sys, csv, os
path, label = sys.argv[1], sys.argv[2]
try:
    rows = list(csv.DictReader(open(path), delimiter='\t'))
except FileNotFoundError:
    rows = []
if not rows:
    print(f"resource stress ({label}): no samples collected")
    sys.exit(0)
mem  = [int(r['mem_used_mb']) for r in rows]
load = [float(r['load1']) for r in rows]
cmem = [int(r['containers_mem_mb']) for r in rows]
def line(name, vals, unit, fmt="{:d}"):
    peak = fmt.format(max(vals)); avg = fmt.format(sum(vals)//len(vals) if isinstance(vals[0],int) else round(sum(vals)/len(vals),2))
    return f"- {name}: peak **{peak}{unit}**, avg {avg}{unit}"
out = os.environ.get("GITHUB_STEP_SUMMARY")
md  = [f"### Resource stress: {label}", "",
       f"- samples: {len(rows)} (every ~3s)",
       line("host memory used", mem, " MB"),
       f"- host load1: peak **{max(load)}**, avg {round(sum(load)/len(load),2)} (4 vCPU runner)",
       line("cluster container memory", cmem, " MB"), ""]
text = "\n".join(md)
print(text)
if out:
    with open(out, "a") as f:
        f.write(text + "\n")
# Machine-readable peaks for median aggregation: "peak_mem_mb peak_load peak_cmem_mb"
metrics = os.environ.get("BENCH_METRICS_OUT")
if metrics:
    with open(metrics, "w") as f:
        f.write(f"{max(mem)} {max(load)} {max(cmem)}\n")
PY
    ;;
  *)
    echo "usage: $0 {start|stop <label>}" >&2; exit 2
    ;;
esac
