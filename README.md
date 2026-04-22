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

| Profile | What it does | Speed |
|---------|-------------|-------|
| `cluster-only` | k3d cluster + kubeconfig | ~15s |
| `platform` | Full Nebari foundational stack via NIC/ArgoCD | ~5-10min |

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

  - uses: actions/setup-go@v6
    with:
      go-version: "1.25"

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

> **Note:** The `platform` profile requires Go to build NIC from source. It currently
> pins to the [`local_git`](https://github.com/nebari-dev/nebari-infrastructure-core/pull/136)
> branch of NIC, which adds `file://` git support for local ArgoCD deployments.

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
| `profile` | <p>Deployment profile. - cluster-only: k3d cluster + kubeconfig, no NIC (fast, ~15s). - platform: full foundational stack via NIC/ArgoCD.</p> | `false` | `cluster-only` |
| `cluster-name` | <p>Name for the k3d cluster (must be unique on the runner)</p> | `false` | `nebari-test` |
| `k8s-version` | <p>Kubernetes version to use (maps to a k3d image tag)</p> | `false` | `1.32.4` |
| `k3d-version` | <p>k3d version to install</p> | `false` | `5.8.3` |
| `resource-summary` | <p>When 'true' (and profile is 'platform'), append a markdown table of pod resource requests/limits and node allocatable capacity to $GITHUB<em>STEP</em>SUMMARY after the platform stack is up. Useful for tracking minimum-spec requirements as the foundational stack evolves.</p> | `false` | `false` |
<!-- action-docs-inputs action="action.yml" -->

<!-- action-docs-outputs action="action.yml" -->
## Outputs

| name | description |
| --- | --- |
| `kubeconfig` | <p>Path to the kubeconfig file for the created cluster</p> |
| `cluster-name` | <p>Name of the created k3d cluster</p> |
| `network-name` | <p>Docker network created for the cluster (platform profile only). Use this in cleanup steps.</p> |
| `gitops-dir` | <p>Local GitOps directory mounted into the cluster (platform profile only)</p> |
| `keycloak-admin-password` | <p>Keycloak admin password (platform profile only)</p> |
| `argocd-admin-password` | <p>ArgoCD admin password (platform profile only)</p> |
| `gateway-ip` | <p>MetalLB gateway IP address (platform profile only)</p> |
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
- **`platform` profile:** Go 1.25+ (use `actions/setup-go@v6`) — NIC is built from source until a release with `file://` git support is available

## License

Apache License 2.0 — see [LICENSE](LICENSE).
