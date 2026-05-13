#!/usr/bin/env bash
# Scenario: consumer-app-via-gitops (issue #47)
#
# Exercises the canonical pattern a downstream consumer uses to deploy their
# app on top of the platform — drop chart/manifests into ${GITOPS_DIR}/<app>/,
# drop an Application manifest into ${GITOPS_DIR}/apps/, commit, chmod, and
# let NIC's root App-of-Apps reconcile through to a Healthy consumer Application.
#
# Doubles as a regression check: if NIC ever changes the path its root
# App-of-Apps watches (currently `apps/`), this scenario goes red and we
# learn before consumers do.

set -euo pipefail

APP_NAME="scenario-consumer-app"

# Derive GITOPS_DIR from the foundational App-of-Apps. The root Application's
# spec.source.repoURL is `file://<gitops-dir>`; strip the scheme.
ROOT_REPO_URL=$(kubectl get application/nebari-root -n argocd \
  -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
GITOPS_DIR="${ROOT_REPO_URL#file://}"

if [[ -z "${GITOPS_DIR}" || ! -d "${GITOPS_DIR}" ]]; then
  echo "::error::Could not resolve GITOPS_DIR from Application/nebari-root.source.repoURL"
  echo "  repoURL: ${ROOT_REPO_URL:-(unset)}"
  exit 1
fi

echo "Using GITOPS_DIR=${GITOPS_DIR}"

# ── Step 1: chart/manifest content into the gitops repo ──────────────────────
mkdir -p "${GITOPS_DIR}/${APP_NAME}"
cat > "${GITOPS_DIR}/${APP_NAME}/workload.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: default
spec:
  selector:
    app: ${APP_NAME}
  ports:
    - port: 80
      targetPort: 80
EOF

# ── Step 2: Application manifest into apps/ ──────────────────────────────────
# NIC's root App-of-Apps watches ${GITOPS_DIR}/apps/*.yaml (excluding root.yaml).
cat > "${GITOPS_DIR}/apps/${APP_NAME}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "file://${GITOPS_DIR}"
    targetRevision: HEAD
    path: ${APP_NAME}
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# ── Step 3: commit ──────────────────────────────────────────────────────────
# gitops-dir is a git working tree; ArgoCD's repo-server reads from HEAD.
git -C "${GITOPS_DIR}" config user.email ci@ci
git -C "${GITOPS_DIR}" config user.name  ci
git -C "${GITOPS_DIR}" add -A
git -C "${GITOPS_DIR}" commit -m "test: add ${APP_NAME}"

# ── Step 4: re-fix perms ─────────────────────────────────────────────────────
# The action's background chmod loop has exited by now; new files default to
# runner-uid-only and argocd-repo-server (uid 999) can't read them.
chmod -R a+rX "${GITOPS_DIR}"

# ── Wait for ArgoCD to converge ──────────────────────────────────────────────
# Path: nebari-root App-of-Apps notices apps/${APP_NAME}.yaml → creates the
# Application object → that Application syncs the workload. Two reconcile
# cycles; budget generously.
echo "Waiting for Application/${APP_NAME} to reach Healthy (max 5 min)..."
STATUS="(none)"
for i in $(seq 1 60); do
  STATUS=$(kubectl get application/${APP_NAME} -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "NotFound")
  echo "  [${i}/60] status: ${STATUS}"
  [[ "${STATUS}" == "Healthy" ]] && break
  sleep 5
done

if [[ "${STATUS}" != "Healthy" ]]; then
  echo "::error::Application/${APP_NAME} did not reach Healthy (last status: ${STATUS})"
  kubectl get application/${APP_NAME} -n argocd -o yaml || true
  kubectl get application/nebari-root -n argocd \
    -o jsonpath='{.status.resources}' | python3 -m json.tool 2>/dev/null || true
  exit 1
fi

# Sanity-check the actual workload came up too.
kubectl wait --for=condition=available deployment/${APP_NAME} \
  -n default --timeout=60s

# ── Cleanup so subsequent scenarios start clean ──────────────────────────────
kubectl delete application/${APP_NAME} -n argocd --wait --timeout=60s 2>/dev/null || true
rm -f "${GITOPS_DIR}/apps/${APP_NAME}.yaml"
rm -rf "${GITOPS_DIR}/${APP_NAME}"
git -C "${GITOPS_DIR}" add -A
git -C "${GITOPS_DIR}" commit -m "test: clean up ${APP_NAME}" 2>/dev/null || true

echo "OK: consumer-app deployed via App-of-Apps, reached Healthy, workload available."
