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
  <a href="https://kubernetes.io"><img src="https://img.shields.io/badge/kubernetes-kind-blue?logo=kubernetes&logoColor=white" alt="Kubernetes"></a>
</p>

## Profiles

| Profile | What it does | Median wall-clock |
|---------|-------------|-------|
| `platform` | Full Nebari foundational stack (kind + NIC/ArgoCD) | [![platform median](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgist.githubusercontent.com%2Fviniciusdc%2Fc975a2e1ee21dd788ea32416e7a57506%2Fraw%2Fbenchmark.json&query=%24.platform_seconds&label=median&suffix=s&color=informational)](https://github.com/nebari-dev/action-nebari-sandbox/actions/workflows/benchmark-timings.yml) * |

<sub>\* Default `nic-version: latest` (pre-built binary). Passing a branch, sha, or `.` builds NIC from source, which adds roughly 2-3 minutes depending on the Go module cache state. Badges are refreshed manually via the [benchmark-timings workflow](.github/workflows/benchmark-timings.yml) — see #42.</sub>

## Usage

### cluster-only

Spin up a bare Kubernetes cluster for quick smoke tests:

```yaml
steps:
  - uses: actions/checkout@v6

  - uses: nebari-dev/action-nebari-sandbox@v2
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

  - uses: nebari-dev/action-nebari-sandbox@v2
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
    run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
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
        certificates.yaml
        cloudnative-pg.yaml
        cluster-issuers.yaml
        envoy-gateway.yaml
        gateway-config.yaml
        httproutes.yaml
        keycloak.yaml
        nebari-landingpage.yaml
        nebari-operator.yaml
        opentelemetry-collector.yaml
        root.yaml                    (the App-of-Apps itself; excluded from its own watch)
    manifests/                       (raw manifests referenced by foundational Apps)
    nic-config.yaml                  (scrubbed config NIC writes back)
```

#### Recommended: use the `add-software-pack` sub-action

Wraps the copy → envsubst → commit ritual into one step, plus a
built-in wait for the resulting ArgoCD `Application` to reach `Healthy`.
Your `application.yaml` can reference `${GITOPS_DIR}` and any other env
vars in scope at invocation time:

```yaml
steps:
  - uses: actions/checkout@v6

  - uses: nebari-dev/action-nebari-sandbox@v2
    id: sandbox
    with:
      profile: platform

  - name: Surface KUBECONFIG for the sub-action's wait
    run: echo "KUBECONFIG=${{ steps.sandbox.outputs.kubeconfig }}" >> "$GITHUB_ENV"

  - uses: nebari-dev/action-nebari-sandbox/add-software-pack@v2
    with:
      gitops-dir:           ${{ steps.sandbox.outputs.gitops-dir }}
      app-name:             my-app
      chart-source:         ./chart
      application-manifest: ./my-app-application.yaml
      # wait-for-application + wait-healthy default to 'true'; the
      # sub-action nudges nebari-root for refresh and blocks until the
      # consumer Application reaches Healthy. Override with 'false' if
      # you'd rather poll yourself.

  - name: Wait for your workload to be available
    run: |
      # Application/my-app is already Healthy at this point. Whatever
      # deployment/service the chart creates is what your tests target.
      kubectl wait --for=condition=available deployment/my-app \
        -n default --timeout=120s

  - name: Run integration tests
    env:
      GATEWAY_IP: ${{ steps.sandbox.outputs.gateway-ip }}
    run: |
      # your tests against the deployed app here

  - name: Cleanup
    if: always()
    run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
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
  project: nebari-apps                        # consumer apps use the `nebari-apps` project (NIC >= v0.10.0)
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

If you'd rather not bring in the sub-action, the underlying ritual is three
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
    # No perm fixup needed: NIC (>= v0.10.0) makes the repo's `.git` readable by
    # the non-root repo-server on commit, and ArgoCD reads committed content from
    # `.git`, not the working tree.
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
      existing:
        context: "k3d-my-cluster"
        storage_class: local-path
    EOF

- uses: nebari-dev/action-nebari-sandbox@v2
  with:
    profile: platform
    cluster-name: my-cluster
    nic-config: /tmp/my-nic-config.yaml
```

#### Server-side OIDC from inside the cluster

Browser-based auth reaches Keycloak from the runner via the gateway IP (the
`curl --resolve` pattern above). But an app pod that validates OIDC *itself*
(fetches the issuer from inside the cluster) needs two things the platform
profile now sets up for you:

- **In-cluster DNS.** Keycloak's discovery document advertises the external
  issuer `https://keycloak.<domain>`, so pods must resolve that exact hostname.
  The action adds a CoreDNS entry mapping `*.<domain>` to the gateway, so
  `keycloak.<domain>` resolves the same inside pods as it does from the runner.
  On by default; set `in-cluster-dns: false` to manage DNS yourself.
- **CA trust.** The gateway serves a selfsigned certificate. The action writes
  its CA to the runner (`ca-cert-path` output) and publishes it in-cluster as
  ConfigMap `nebari-sandbox-ca` (key `ca.crt`) in `kube-public`. Mount it in
  your pod so standard TLS trusts `https://<domain>`:

```yaml
- name: Give my-app the sandbox CA
  env:
    KUBECONFIG: ${{ steps.sandbox.outputs.kubeconfig }}
  run: |
    # Copy the well-known CA into your app's namespace, then mount it and point
    # the runtime at it (SSL_CERT_FILE / REQUESTS_CA_BUNDLE / NODE_EXTRA_CA_CERTS).
    kubectl get configmap nebari-sandbox-ca -n kube-public -o yaml \
      | sed 's/namespace: kube-public/namespace: default/' \
      | kubectl apply -f -
```

> **TLS SANs:** only `<domain>`, `keycloak.<domain>`, and `argocd.<domain>` are
> covered by the gateway certificate today, so those are the hostnames that both
> resolve *and* pass TLS from inside the cluster.

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
| `cluster-name` | <p>Name for the deployment. Used as NIC's <code>project_name</code> and as the kind cluster name (context <code>kind-&lt;cluster-name&gt;</code>). Must be unique on the runner.</p> | `false` | `nebari-test` |
| `resource-summary` | <p>When 'true', append a markdown table of pod resource requests/limits and node allocatable capacity to $GITHUB<em>STEP</em>SUMMARY after the platform stack is up. Useful for tracking minimum-spec requirements as the foundational stack evolves.</p> | `false` | `false` |
| `timing-report` | <p>When 'true', record wall-clock durations for key phases (nic deploy, etc.) and append a markdown timing table to $GITHUB<em>STEP</em>SUMMARY. Intended for benchmarking and profiling CI runs; no effect when 'false'.</p> | `false` | `false` |
| `nic-version` | <p>NIC version to install. Requires NIC v0.13.0 or newer: this action uses NIC's <code>local</code> (kind) cluster provider and <code>local</code> repository provider, which the v0.13.0 repository-provider split introduced. - 'latest' (default): downloads the latest released pre-built binary. - 'vX.Y.Z': downloads that release's pre-built binary (&gt;= v0.13.0). - '.': builds from $GITHUB_WORKSPACE (use when the consumer has the   NIC repo checked out, e.g. NIC's own self-tests).</p> <ul> <li>Any other string (branch name, tag, commit sha): clones that ref and builds from source. Requires Go in the consumer's workflow (add actions/setup-go before this action). Ignored when <code>nic-binary</code> is set. Leave at the default if you use <code>nic-binary</code>; setting both to meaningful values is an error.</li> </ul> | `false` | `latest` |
| `nic-binary` | <p>Path to a pre-built <code>nic</code> binary on the runner. When set, the action installs it directly and ignores <code>nic-version</code> — use this to build <code>nic</code> once in an earlier job (e.g. upload/download it as an artifact) and reuse it across per-provider or matrix jobs instead of rebuilding from source each time. Mutually exclusive with a non-default <code>nic-version</code>.</p> | `false` | `""` |
| `nic-config` | <p>Path to a consumer-supplied NIC config file. When set, the action skips its built-in config template and passes this file to <code>nic deploy -f</code> directly. For the action's outputs to resolve, the config's <code>project_name</code> must equal <code>cluster-name</code>, and it must use the <code>local</code> cluster provider (<code>cluster.local</code>) and the <code>local</code> repository provider (<code>repository.local</code>), which is what the action provisions. The action does not validate this; NIC's config parser surfaces real mismatches at deploy time.</p> | `false` | `""` |
| `in-cluster-dns` | <p>When 'true' (default), add a CoreDNS entry so the external Nebari hostnames (<code>*.&lt;domain&gt;</code>, e.g. <code>keycloak.nebari.local</code>) resolve to the gateway from INSIDE the cluster. Required for consumer pods doing server-side OIDC: Keycloak's discovery document advertises the external issuer, so a pod must reach that same hostname (see #69). Only <code>keycloak.&lt;domain&gt;</code>, <code>argocd.&lt;domain&gt;</code>, and <code>&lt;domain&gt;</code> have valid TLS SANs. Set 'false' if you manage in-cluster DNS yourself.</p> | `false` | `true` |
<!-- action-docs-inputs action="action.yml" -->

<!-- action-docs-outputs action="action.yml" -->
## Outputs

| name | description |
| --- | --- |
| `kubeconfig` | <p>Path to the kubeconfig file for the created kind cluster.</p> |
| `cluster-name` | <p>Name of the deployment (NIC project_name; kind context is <code>kind-&lt;cluster-name&gt;</code>).</p> |
| `gitops-dir` | <p>Local GitOps directory NIC created and mounted into the cluster (~/.nic/gitops/<cluster-name>).</p> |
| `keycloak-admin-password` | <p>Keycloak admin password for the <em>master</em> realm. Use <code>keycloak-realm-admin-password</code> for the nebari realm.</p> |
| `keycloak-realm-admin-password` | <p>Keycloak admin password for the <em>nebari</em> realm. Provisioned asynchronously by NIC's realm-setup PostSync hook after Keycloak becomes Ready, so this may be empty if the secret has not materialized by the time extract-outputs.sh polls (see #27). When empty, read the <code>nebari-realm-admin-credentials</code> secret in the <code>keycloak</code> namespace after your own wait-for-realm step.</p> |
| `argocd-admin-password` | <p>ArgoCD admin password.</p> |
| `gateway-ip` | <p>Gateway LoadBalancer IP, assigned by MetalLB from the kind Docker network pool (routable from the Linux runner).</p> |
| `keycloak-issuer-url` | <p>External public issuer URL for the Keycloak deployment, e.g. <code>https://keycloak.nebari.local</code>. Derived from the <code>domain</code> field in the NIC config, matching NIC's own formula. Useful for JWT <code>iss</code> claim validation in consumer e2e tests.</p> |
| `domain` | <p>The Nebari domain the platform was deployed with, e.g. <code>nebari.local</code>. Read from the NIC config in the gitops repo.</p> |
| `ca-cert-path` | <p>Path on the runner to the sandbox gateway's CA certificate, extracted from the <code>nebari-gateway-tls</code> secret. Use it for runner-side <code>curl --cacert</code>, or to build a ConfigMap/Secret your pods mount so they trust <code>https://&lt;domain&gt;</code> (the gateway serves a selfsigned cert). The same CA is published in-cluster as ConfigMap <code>nebari-sandbox-ca</code> (key <code>ca.crt</code>) in <code>kube-public</code>. Empty if the gateway TLS secret could not be read (see #69).</p> |
<!-- action-docs-outputs action="action.yml" -->

## Cleanup

The action does not automatically delete the cluster. Add a cleanup step to your workflow:

```yaml
# cluster-only
- name: Cleanup
  if: always()
  run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}

# platform
- name: Cleanup
  if: always()
  run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
```

## Requirements

- **Both profiles:** `ubuntu-24.04` (or `ubuntu-latest`) runner with Docker (pre-installed on GitHub-hosted runners)
- **`platform` profile:** none extra by default (NIC's pre-built binary is downloaded). Go 1.26+ via `actions/setup-go@v6` is only needed if you set `nic-version` to a non-release ref (branch, sha, or `.`) and want to build from source (match NIC's `go.mod`).

## Contributing

Adding a step, script, or test? See [CONTRIBUTING.md](CONTRIBUTING.md) for the
conventions — the gates-fail/extractors-warn split, where tests belong (unit vs
scenario vs inline), and the script/workflow idioms.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
