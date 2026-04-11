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
  <strong>A reusable GitHub Action that bootstraps a local Kubernetes test environment for Nebari component testing. Instead of each repo maintaining its own cluster setup scripts, this action provides a single, consistent way to spin up a test environment.
</p>

## Profiles

| Profile | What it does | Speed |
|---------|-------------|-------|
| `cluster-only` | k3d cluster + kubeconfig | ~15s |
| `platform` | Full Nebari stack via NIC/ArgoCD (cert-manager, Envoy Gateway, Keycloak, nebari-operator) | _Coming soon_ |

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

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `profile` | Deployment profile (`cluster-only` or `platform`) | `cluster-only` |
| `cluster-name` | Name for the k3d cluster | `nebari-test` |
| `k8s-version` | Kubernetes version | `1.32.4` |
| `k3d-version` | k3d version to install | `5.8.3` |

## Outputs

| Output | Description |
|--------|-------------|
| `kubeconfig` | Path to the kubeconfig file |
| `cluster-name` | Name of the created k3d cluster |

## Cleanup

The action does not automatically delete the cluster. Add a cleanup step to your workflow:

```yaml
- name: Cleanup
  if: always()
  run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }}
```

## Requirements

Runs on `ubuntu-latest`. Requires Docker (pre-installed on GitHub-hosted runners).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
