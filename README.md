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
| `platform` | Full Nebari stack via NIC/ArgoCD (cert-manager, Envoy Gateway, Keycloak, MetalLB, nebari-operator) | ~5-10min |

## Usage

### cluster-only

Spin up a bare Kubernetes cluster for quick smoke tests:

```yaml
steps:
  - uses: actions/checkout@v4

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
```

### platform

Deploy the full Nebari foundational stack for integration testing:

```yaml
steps:
  - uses: actions/checkout@v6

  - uses: actions/setup-go@v5
    with:
      go-version: "1.24"

  - uses: nebari-dev/action-nebari-sandbox@main
    id: sandbox
    with:
      profile: platform

  - name: Run integration tests
    run: |
      kubectl get applications -n argocd
      # your integration tests here

  - name: Cleanup
    if: always()
    run: |
      k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
      docker network rm nebari-${{ steps.sandbox.outputs.cluster-name }}-net 2>/dev/null || true
```

> **Note:** The `platform` profile requires Go to build NIC from source. It currently
> pins to the [`local_git`](https://github.com/nebari-dev/nebari-infrastructure-core/pull/136)
> branch of NIC, which adds `file://` git support for local ArgoCD deployments.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `profile` | Deployment profile (`cluster-only` or `platform`) | `cluster-only` |
| `cluster-name` | Name for the k3d cluster | `nebari-test` |
| `k8s-version` | Kubernetes version | `1.32.4` |
| `k3d-version` | k3d version to install | `5.8.3` |

## Outputs

| Output | Description | Profile |
|--------|-------------|---------|
| `kubeconfig` | Path to the kubeconfig file | all |
| `cluster-name` | Name of the created k3d cluster | all |
| `keycloak-admin-password` | Keycloak admin password | `platform` |
| `argocd-admin-password` | ArgoCD admin password | `platform` |
| `gateway-ip` | MetalLB gateway IP address | `platform` |

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
    docker network rm nebari-${{ steps.sandbox.outputs.cluster-name }}-net 2>/dev/null || true
```

## Requirements

- **Both profiles:** `ubuntu-latest` runner with Docker (pre-installed on GitHub-hosted runners)
- **`platform` profile:** Go 1.24+ (use `actions/setup-go@v5`) — NIC is built from source until a release with `file://` git support is available

## License

Apache License 2.0 — see [LICENSE](LICENSE).
