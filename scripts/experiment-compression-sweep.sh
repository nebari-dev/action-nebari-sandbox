#!/usr/bin/env bash
# Validation experiment for #33: compression sweep.
#
# Snapshots the k3d server volume as a raw tar (one docker pass), then
# re-compresses it with multiple zstd configurations. Optionally also runs
# `crictl rmi --prune` first and takes a second snapshot to measure the
# cost saved by dropping unreferenced images.
#
# Outputs a TSV plus a markdown table on $GITHUB_STEP_SUMMARY.
set -euo pipefail

CLUSTER="${1:?usage: experiment-compression-sweep.sh <cluster> <output-dir>}"
OUTPUT_DIR="${2:?}"
SERVER="k3d-${CLUSTER}-server-0"

mkdir -p "${OUTPUT_DIR}"
RESULTS="${OUTPUT_DIR}/compression-results.tsv"
echo -e "stage\tvariant\tsize_bytes\tcompress_seconds\tdecompress_seconds" > "${RESULTS}"

_t() { date +%s; }
fmt_size() { numfmt --to=iec --suffix=B "$1"; }

# ------------------------------------------------------------ raw + variants
take_raw_tar() {
  local label="$1" out_path="$2"
  echo "::group::Raw tar (${label})"
  local t=$(_t)
  docker run --rm --volumes-from "${SERVER}" busybox \
    tar -C /var/lib/rancher/k3s -cf - . 2>/dev/null > "${out_path}"
  local sz=$(stat -c %s "${out_path}")
  echo "raw tar: $(($(_t) - t))s, size: $(fmt_size "${sz}")"
  echo "::endgroup::"
}

run_variant() {
  local stage="$1" name="$2" cmd="$3" in_path="$4"
  local out_path="${OUTPUT_DIR}/${stage}.${name}.zst"

  echo "::group::[${stage}] ${name}"
  local t=$(_t)
  eval "${cmd}" < "${in_path}" > "${out_path}"
  local ct=$(($(_t) - t))

  t=$(_t)
  zstd -d -c "${out_path}" | wc -c >/dev/null
  local dt=$(($(_t) - t))

  local sz=$(stat -c %s "${out_path}")
  echo "compress: ${ct}s, decompress: ${dt}s, size: $(fmt_size "${sz}")"
  printf '%s\t%s\t%s\t%s\t%s\n' "${stage}" "${name}" "${sz}" "${ct}" "${dt}" >> "${RESULTS}"

  rm -f "${out_path}"
  echo "::endgroup::"
}

sweep() {
  local stage="$1" raw_path="$2"
  run_variant "${stage}" "baseline"        "zstd -T0"                "${raw_path}"
  run_variant "${stage}" "long27"          "zstd -T0 --long=27"      "${raw_path}"
  run_variant "${stage}" "level19"         "zstd -T0 -19"            "${raw_path}"
  run_variant "${stage}" "long27-level19"  "zstd -T0 --long=27 -19"  "${raw_path}"
}

# ---------------------------------------------------------------------------
# Stage 1: baseline (no prune)
# ---------------------------------------------------------------------------
echo "::group::Stop cluster for consistent snapshot"
k3d cluster stop "${CLUSTER}"
echo "::endgroup::"

take_raw_tar "baseline" /tmp/raw-baseline.tar
sweep "baseline" /tmp/raw-baseline.tar

# ---------------------------------------------------------------------------
# Stage 2: post-prune
# ---------------------------------------------------------------------------
echo "::group::Restart cluster briefly for crictl rmi --prune"
k3d cluster start "${CLUSTER}"
sleep 5
# crictl runs inside the k3d server. Need to give it the right runtime endpoint.
docker exec "${SERVER}" sh -c \
  'crictl --runtime-endpoint=unix:///run/k3s/containerd/containerd.sock rmi --prune 2>&1 | tail -20' \
  || echo "(crictl prune failed — proceeding with what we have)"
k3d cluster stop "${CLUSTER}"
echo "::endgroup::"

take_raw_tar "post-prune" /tmp/raw-post-prune.tar
sweep "post-prune" /tmp/raw-post-prune.tar

rm -f /tmp/raw-baseline.tar /tmp/raw-post-prune.tar

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo "::group::Summary"
{
  echo "## Compression sweep results"
  echo
  echo "| Stage | Variant | Size | Compress | Decompress |"
  echo "|---|---|---:|---:|---:|"
  while IFS=$'\t' read -r stage variant sz ct dt; do
    [ "${stage}" = "stage" ] && continue
    printf '| %s | %s | %s | %ss | %ss |\n' \
      "${stage}" "${variant}" "$(fmt_size "${sz}")" "${ct}" "${dt}"
  done < "${RESULTS}"
  echo
  echo "Raw tar sizes (uncompressed):"
  echo "- baseline: see compress timings vs raw size"
  echo "- Differences between baseline and post-prune rows show \`crictl rmi --prune\` impact."
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "::endgroup::"

cat "${RESULTS}"
