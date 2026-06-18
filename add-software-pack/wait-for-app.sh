#!/usr/bin/env bash
# Wait for the consumer Application registered by register-pack.sh to be
# created by NIC's root App-of-Apps, optionally also for it to reach Healthy.
#
# Called by add-software-pack/action.yml when inputs.wait-for-application is
# 'true'. The consumer must have ${KUBECONFIG} set in the environment (e.g.
# via `echo "KUBECONFIG=..." >> $GITHUB_ENV` after the parent action).

set -euo pipefail

: "${APP_NAME:?APP_NAME is required}"
WAIT_HEALTHY="${WAIT_HEALTHY:-true}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-5m}"

# Normalize WAIT_TIMEOUT once so both wait phases agree on it. The exists phase
# parses it into integer seconds and is lenient (a bare number is treated as
# seconds), but the Healthy phase hands it straight to `kubectl wait --timeout`,
# which is strict and rejects a unit-less value ("missing unit in duration").
# That mismatch let `300` pass phase 1 and then hard-fail phase 2, where the
# rejected argument was surfaced as a misleading "did not reach Healthy" timeout
# (#64). Append `s` to a bare number, then validate the shape up front and fail
# fast with the real reason rather than letting `kubectl wait` mis-report it.
if [[ "${WAIT_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  WAIT_TIMEOUT="${WAIT_TIMEOUT}s"
fi
if [[ ! "${WAIT_TIMEOUT}" =~ ^[0-9]+(s|m|h)$ ]]; then
  echo "::error::wait-timeout must be a kubectl-style duration like 300s, 5m, or 1h (got '${WAIT_TIMEOUT}')."
  exit 1
fi

echo "::group::Wait for Application/${APP_NAME}"

# Nudge nebari-root to reconcile now rather than at its next natural polling
# interval (~3 min). Saves ~2-3 min of consumer wait every run. The
# annotation is idempotent; ArgoCD strips it during the resulting sync.
echo "Nudging nebari-root for refresh..."
kubectl annotate -n argocd application/nebari-root \
  argocd.argoproj.io/refresh=normal --overwrite

# Convert WAIT_TIMEOUT to integer seconds for the existence-poll loop.
# Accepts the same shape as `kubectl wait --timeout` (5m, 120s, 1h).
seconds_from_duration() {
  local d="$1"
  case "$d" in
    *s) echo "${d%s}" ;;
    *m) echo $(( ${d%m} * 60 )) ;;
    *h) echo $(( ${d%h} * 3600 )) ;;
    *)  echo "$d" ;;  # bare number, assume seconds
  esac
}
TIMEOUT_S=$(seconds_from_duration "${WAIT_TIMEOUT}")

# Phase 1: poll for the Application object to exist. We can't use
# `kubectl wait` here because the object doesn't exist yet, and `kubectl
# wait` on a missing object errors immediately rather than waiting for
# creation.
echo "Waiting up to ${WAIT_TIMEOUT} for application/${APP_NAME} to exist..."
deadline=$(( $(date +%s) + TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  if kubectl get application/${APP_NAME} -n argocd >/dev/null 2>&1; then
    echo "  application/${APP_NAME} exists"
    break
  fi
  sleep 3
done
if ! kubectl get application/${APP_NAME} -n argocd >/dev/null 2>&1; then
  echo "::error::Timed out after ${WAIT_TIMEOUT} waiting for application/${APP_NAME} to be created by nebari-root."
  echo "  This usually means either:"
  echo "    1. The consumer Application's metadata.name doesn't match the app-name input."
  echo "       (register-pack.sh writes apps/<app-name>.yaml; nebari-root creates the"
  echo "        Application using whatever metadata.name is inside that file.)"
  echo "    2. nebari-root itself is unhealthy. Inspect with:"
  echo "         kubectl get application/nebari-root -n argocd -o yaml"
  exit 1
fi

# Phase 2: optionally wait for Healthy. `kubectl wait` is the right tool
# here because the object now exists; jsonpath form matches what consumers
# typically write themselves.
if [[ "${WAIT_HEALTHY}" == "true" ]]; then
  echo "Waiting up to ${WAIT_TIMEOUT} for application/${APP_NAME} to reach Healthy..."
  if ! kubectl wait --for=jsonpath='{.status.health.status}=Healthy' \
       application/${APP_NAME} -n argocd --timeout="${WAIT_TIMEOUT}"; then
    echo "::error::application/${APP_NAME} did not reach Healthy within ${WAIT_TIMEOUT}."
    echo "  Current status:"
    kubectl get application/${APP_NAME} -n argocd \
      -o jsonpath='{.status.health.status} / {.status.sync.status}'$'\n' || true
    echo "  Inspect with:"
    echo "    kubectl get application/${APP_NAME} -n argocd -o yaml"
    exit 1
  fi
  echo "  application/${APP_NAME} is Healthy"
fi

echo "::endgroup::"
