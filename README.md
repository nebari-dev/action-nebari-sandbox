<p align="center">
  <a href="https://nebari.dev">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/nebari-dev/nebari-design/main/logo-mark/horizontal/standard/Nebari-Logo-Horizontal-Lockup-White-text.png">
      <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/nebari-dev/nebari-design/main/logo-mark/horizontal/standard/Nebari-Logo-Horizontal-Lockup.png">
      <img alt="Nebari" src="docs/Nebari-Logo-Horizontal-Lockup.png" width="300">
    </picture>
  </a>
</p>

<h1 align="center">Setup Nebari Sandbox</h1>

<p align="center">
  <strong>A reusable GitHub Action that bootstraps a local Kubernetes test environment for Nebari component testing. Instead of each repo maintaining its own cluster setup scripts, this action provides a single, consistent way to spin up a test environment.</strong>
</p>

<p align="center">
  <a href="https://github.com/nebari-dev/action-nebari-sandbox/actions/workflows/test-action.yml"><img src="https://github.com/nebari-dev/action-nebari-sandbox/actions/workflows/test-action.yml/badge.svg" alt="Test Action"></a>
  <a href="https://github.com/nebari-dev/action-nebari-sandbox/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-green" alt="License"></a>
  <a href="https://kubernetes.io"><img src="https://img.shields.io/badge/kubernetes-v1.32-blue?logo=kubernetes&logoColor=white" alt="Kubernetes"></a>
  <a href="https://k3d.io"><img src="https://img.shields.io/badge/k3d-v5.8.3-purple" alt="k3d"></a>
</p>

## Profiles

| Profile | What it does | Median wall-clock |
|---------|-------------|-------|
| `cluster-only` | k3d cluster + kubeconfig | [![cluster-only median](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgist.githubusercontent.com%2Fviniciusdc%2Fc975a2e1ee21dd788ea32416e7a57506%2Fraw%2Fbenchmark.json&query=%24.cluster_only_seconds&label=median&suffix=s&color=informational)](https://github.com/nebari-dev/action-nebari-sandbox/actions/workflows/benchmark-timings.yml) |
| `platform` | Full Nebari foundational stack via NIC/ArgoCD | [![platform median](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgist.githubusercontent.com%2Fviniciusdc%2Fc975a2e1ee21dd788ea32416e7a57506%2Fraw%2Fbenchmark.json&query=%24.platform_seconds&label=median&suffix=s&color=informational)](https://github.com/nebari-dev/action-nebari-sandbox/actions/workflows/benchmark-timings.yml) * |

<sub>\* Default `nic-version: latest` (pre-built binary). Passing a branch, sha, or `.` builds NIC from source, which adds roughly 2-3 minutes depending on the Go module cache state. Badges are refreshed manually via the [benchmark-timings workflow](.github/workflows/benchmark-timings.yml) — see #42.</sub>

## Usage

### cluster-only

Spin up a bare Kubernetes cluster for quick smoke tests:

```yaml
steps:
  - uses: actions/checkout@v6

  - uses: nebari-dev/action-nebari-sandbox@v1
    id: sandbox
    with:
      profile: cluster-only

  - name: Run tests
    run: |
      kubectl get nodes
      # your tests here
    env:
      KUBECONFIG: ${{ steps.sandbox.outputs.kubeconfig }}

  - name: Cleanup
    if: always()
    run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
```

### platform

Deploy the full Nebari foundational stack for integration testing:

```yaml
steps:
  - uses: actions/checkout@v6

  - uses: nebari-dev/action-nebari-sandbox@v1
    id: sandbox
    with:
      profile: platform

  - name: Run integration tests
    env:
      KEYCLOAK_ADMIN_PASSWORD: ${{ steps.sandbox.outputs.keycloak-admin-password }}
      ARGOCD_ADMIN_PASSWORD: ${{ steps.sandbox.outputs.argocd-admin-password }}
      GATEWAY_IP: ${{ steps.sandbox.outputs.gateway-ip }}
    run: |
      kubectl get applications -n argocd
      # Reach the gateway from inside the runner:
      curl -sk --resolve "keycloak.nebari.local:443:${GATEWAY_IP}" \
        https://keycloak.nebari.local/realms/master/.well-known/openid-configuration
      # your integration tests here

  - name: Cleanup
    if: always()
    run: |
      k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
      docker network rm ${{ steps.sandbox.outputs.network-name }} 2>/dev/null || true
```

> **Note:** by default the `platform` profile downloads NIC's latest pre-built
> binary. Pass `nic-version: <branch>` (or `'.'` to use `$GITHUB_WORKSPACE`)
> if you want to build NIC from source — that path needs `actions/setup-go`
> in your workflow before this action.

### platform + consumer app via GitOps

Most consumers don't just want to spin up the platform — they want to deploy
their own application on top of it and run an end-to-end test. The `platform`
profile leaves a fully-bootstrapped local git repository at
`${{ steps.sandbox.outputs.gitops-dir }}` (default `/tmp/nebari-gitops-<cluster>`)
bind-mounted into the k3d node. NIC seeds it with a root
[App-of-Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
(`Application/nebari-root`) that watches `${GITOPS_DIR}/apps/` for any `*.yaml`
and creates the corresponding ArgoCD `Application` automatically. Drop your
consumer Application manifest into that directory and the platform takes care
of the rest.

The foundational stack lives there too — knowing the filenames matters because
reusing one means deliberately *replacing* that Application:

```
${GITOPS_DIR}/
    apps/                            (root App-of-Apps watches this directory)
        cert-manager.yaml
        cluster-issuers.yaml
        gateway-config.yaml
        httproutes.yaml
        keycloak.yaml
        metallb.yaml
        nebari-landingpage.yaml
        postgresql.yaml
        root.yaml                    (the App-of-Apps itself; excluded from its own watch)
    manifests/                       (raw manifests referenced by foundational Apps)
    nic-config.yaml                  (scrubbed config NIC writes back)
```

#### Recommended: use the `add-software-pack` sub-action

Wraps the copy → envsubst → commit → chmod ritual into one step. Your
`application.yaml` can reference `${GITOPS_DIR}` and any other env vars in
scope at invocation time:

```yaml
steps:
  - uses: actions/checkout@v6

  - uses: nebari-dev/action-nebari-sandbox@v1
    id: sandbox
    with:
      profile: platform

  - uses: nebari-dev/action-nebari-sandbox/add-software-pack@v1
    with:
      gitops-dir:           ${{ steps.sandbox.outputs.gitops-dir }}
      app-name:             my-app
      chart-source:         ./chart
      application-manifest: ./my-app-application.yaml

  - name: Wait for ArgoCD to reconcile
    env:
      KUBECONFIG: ${{ steps.sandbox.outputs.kubeconfig }}
    run: |
      kubectl wait --for=jsonpath='{.status.health.status}=Healthy' \
        application/my-app -n argocd --timeout=300s
      kubectl wait --for=condition=available deployment/my-app \
        -n default --timeout=120s

  - name: Run integration tests
    env:
      KUBECONFIG: ${{ steps.sandbox.outputs.kubeconfig }}
      GATEWAY_IP: ${{ steps.sandbox.outputs.gateway-ip }}
    run: |
      # your tests against the deployed app here

  - name: Cleanup
    if: always()
    run: |
      k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
      docker network rm ${{ steps.sandbox.outputs.network-name }} 2>/dev/null || true
```

A minimal `application.yaml` modeled on the foundational landing-page App
([source](https://github.com/nebari-dev/nebari-infrastructure-core/blob/main/pkg/argocd/templates/apps/nebari-landingpage.yaml)),
with the `repoURL` pointing at the local gitops repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default                            # or `foundational` — both work
  source:
    repoURL: "file://${GITOPS_DIR}"           # envsubst-rendered by the sub-action
    targetRevision: HEAD
    path: my-app                              # matches `app-name` above
    directory:
      recurse: false                          # or use `helm:`, `kustomize:`, etc.
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

#### Without the sub-action

If you'd rather not bring in the sub-action, the underlying ritual is four
steps. Useful when you want fine-grained control over the commit, or to keep
the workflow free of extra `uses:` lines:

```yaml
- name: Register my-app
  env:
    GITOPS_DIR: ${{ steps.sandbox.outputs.gitops-dir }}
  run: |
    # 1. Chart/manifests into the gitops repo
    cp -r chart/ "${GITOPS_DIR}/my-app/"

    # 2. Application manifest into apps/ (envsubst expands ${GITOPS_DIR})
    envsubst < my-app-application.yaml > "${GITOPS_DIR}/apps/my-app.yaml"

    # 3. Commit. ${GITOPS_DIR} is a git working tree; ArgoCD reads HEAD.
    #    Use `-c` flags instead of `git config` so the identity stays
    #    request-scoped — otherwise it leaks into ${GITOPS_DIR}/.git/config
    #    and any subsequent `git` call inherits it.
    git -C "${GITOPS_DIR}" add -A
    git -C "${GITOPS_DIR}" \
      -c user.email=ci@my-app \
      -c user.name=my-app-ci \
      commit -m "add my-app"

    # 4. Re-fix perms. argocd-repo-server runs as uid 999 in-cluster.
    chmod -R a+rX "${GITOPS_DIR}"
```

#### Customizing the NIC config

If you need the platform itself configured differently (e.g. a different
domain, a custom certificate, additional `git_repository` settings), pass
`nic-config` with a path to your own config file. Two fields must match
what the action actually provisioned — see the input docs for details:

```yaml
- name: Write a custom NIC config
  run: |
    cat > /tmp/my-nic-config.yaml <<'EOF'
    project_name: my-project
    domain: nebari.local
    certificate:
      type: selfsigned
    git_repository:
      url: "file:///tmp/nebari-gitops-my-cluster"
      branch: main
    cluster:
      local:
        kube_context: "k3d-my-cluster"
        node_selectors:
          general: { kubernetes.io/os: linux }
          user:    { kubernetes.io/os: linux }
          worker:  { kubernetes.io/os: linux }
    EOF

- uses: nebari-dev/action-nebari-sandbox@v1
  with:
    profile: platform
    cluster-name: my-cluster
    nic-config: /tmp/my-nic-config.yaml
```

<!--
  Inputs and Outputs sections below are auto-generated from action.yml by
  npm's `action-docs` (run by .github/workflows/docs-check.yml on each PR).

  To update locally:
      npx --yes action-docs@2.4.0 --no-banner --update-readme README.md

  Do not edit the contents between the marker comments by hand.
-->

<!-- action-docs-inputs action="action.yml" -->
## Inputs

| name | description | required | default |
| --- | --- | --- | --- |
| `profile` | <p>Deployment profile. - cluster-only: k3d cluster + kubeconfig, no NIC. - platform: full foundational stack via NIC/ArgoCD. See the Profiles table in the README for current median wall-clock durations (auto-refreshed via the benchmark-timings workflow).</p> | `false` | `cluster-only` |
| `cluster-name` | <p>Name for the k3d cluster (must be unique on the runner)</p> | `false` | `nebari-test` |
| `k8s-version` | <p>Kubernetes version to use (maps to a k3d image tag)</p> | `false` | `1.32.4` |
| `k3d-version` | <p>k3d version to install</p> | `false` | `5.8.3` |
| `resource-summary` | <p>When 'true' (and profile is 'platform'), append a markdown table of pod resource requests/limits and node allocatable capacity to $GITHUB<em>STEP</em>SUMMARY after the platform stack is up. Useful for tracking minimum-spec requirements as the foundational stack evolves.</p> | `false` | `false` |
| `timing-report` | <p>When 'true', record wall-clock durations for key phases (k3s image pull, k3d cluster create, nic deploy, etc.) and append a markdown timing table to $GITHUB<em>STEP</em>SUMMARY. Works with both profiles. Intended for benchmarking and profiling CI runs; has no effect on normal operation when 'false'.</p> | `false` | `false` |
| `nic-version` | <p>NIC version to install (platform profile only). - 'latest' (default): downloads the latest released pre-built binary. - 'vX.Y.Z': downloads a specific release's pre-built binary. - '.': builds from $GITHUB_WORKSPACE (use when the consumer has the   NIC repo checked out, e.g. NIC's own self-tests).</p> <ul> <li>Any other string (branch name, tag, commit sha): clones that ref and builds from source. Requires Go in the consumer's workflow (add actions/setup-go before this action).</li> </ul> | `false` | `latest` |
| `nic-config` | <p>Path to a consumer-supplied NIC config file (platform profile only). When set, the action skips its built-in config template and passes this file to <code>nic deploy -f</code> directly. The consumer is responsible for matching the rest of the action's setup — two fields in particular must point at what the action actually provisioned:</p> <ul> <li><code>cluster.local.kube_context</code> — derived as <code>k3d-&lt;cluster-name&gt;</code> (e.g. <code>k3d-nebari-test</code> for the default cluster-name).</li> <li><code>git_repository.url</code> — derived as <code>file:///tmp/nebari-gitops-&lt;cluster-name&gt;</code> (a hostPath mount into the k3d node so ArgoCD's repo-server can read it).</li> </ul> <p>The action does not validate these; NIC's config parser will surface real mismatches at deploy time. When unset (default), the action generates its standard config as before.</p> | `false` | `""` |
<!-- action-docs-inputs action="action.yml" -->

<!-- action-docs-outputs action="action.yml" -->
## Outputs

| name | description |
| --- | --- |
| `kubeconfig` | <p>Path to the kubeconfig file for the created cluster</p> |
| `cluster-name` | <p>Name of the created k3d cluster</p> |
| `network-name` | <p>Docker network created for the cluster (platform profile only). Use this in cleanup steps.</p> |
| `gitops-dir` | <p>Local GitOps directory mounted into the cluster (platform profile only)</p> |
| `keycloak-admin-password` | <p>Keycloak admin password for the <em>master</em> realm (platform profile only). Use <code>keycloak-realm-admin-password</code> for the nebari realm.</p> |
| `keycloak-realm-admin-password` | <p>Keycloak admin password for the <em>nebari</em> realm (platform profile only). Provisioned asynchronously by NIC's realm-setup PostSync hook after Keycloak becomes Ready, so this output may be empty if the secret has not materialized by the time <code>extract-outputs.sh</code> polls (see #27 for the planned wait-for-realm input). When empty, consumers can fall back to reading the <code>nebari-realm-admin-credentials</code> secret in the <code>keycloak</code> namespace after their own wait-for-realm step.</p> |
| `argocd-admin-password` | <p>ArgoCD admin password (platform profile only)</p> |
| `gateway-ip` | <p>MetalLB gateway IP address (platform profile only)</p> |
| `keycloak-issuer-url` | <p>External public issuer URL for the Keycloak deployment (platform profile only), e.g. <code>https://keycloak.nebari.local</code>. Derived from the <code>domain</code> field in the NIC config NIC wrote to the gitops repo, matching NIC's own formula. Useful for JWT <code>iss</code> claim validation in consumer e2e tests.</p> |
<!-- action-docs-outputs action="action.yml" -->

## Cleanup

The action does not automatically delete the cluster. Add a cleanup step to your workflow:

```yaml
# cluster-only
- name: Cleanup
  if: always()
  run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}

# platform (also removes the Docker network)
- name: Cleanup
  if: always()
  run: |
    k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
    docker network rm ${{ steps.sandbox.outputs.network-name }} 2>/dev/null || true
```

## Requirements

- **Both profiles:** `ubuntu-24.04` (or `ubuntu-latest`) runner with Docker (pre-installed on GitHub-hosted runners)
- **`platform` profile:** none extra by default (NIC's pre-built binary is downloaded). Go 1.25+ via `actions/setup-go@v6` is only needed if you set `nic-version` to a non-release ref (branch, sha, or `.`) and want to build from source.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
