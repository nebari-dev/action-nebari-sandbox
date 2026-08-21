import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

import * as core from '@actions/core'
import * as exec from '@actions/exec'

// Root of the action checkout, where scripts/ lives. GitHub sets
// GITHUB_ACTION_PATH; fall back to the bundle location (dist/ -> ..) for
// `local-action`-style runs.
function actionRoot(): string {
  return (
    process.env.GITHUB_ACTION_PATH ||
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
  )
}

// Drop undefined values so the object satisfies exec's {[k]:string} env type.
function cleanEnv(extra: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [k, v] of Object.entries(process.env))
    if (v !== undefined) out[k] = v
  return { ...out, ...extra }
}

// Parse the `key=value` lines a helper script appends to $GITHUB_OUTPUT /
// $GITHUB_ENV (the format the composite steps used). Splits on the first `=`.
function parseKeyVals(file: string): Record<string, string> {
  const out: Record<string, string> = {}
  if (!fs.existsSync(file)) return out
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const i = line.indexOf('=')
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1)
  }
  return out
}

interface StepResult {
  outputs: Record<string, string>
  envs: Record<string, string>
}

// Run one of the action's bash helpers, capturing whatever it writes to
// $GITHUB_OUTPUT / $GITHUB_ENV by pointing those at per-step temp files. This
// lets the TS orchestrator reuse the shell helpers unchanged and thread their
// values (gitops-dir, gateway-ip, ...) between steps and out as action outputs.
async function runStep(
  label: string,
  script: string,
  extraEnv: Record<string, string>
): Promise<StepResult> {
  const dir = process.env.RUNNER_TEMP || os.tmpdir()
  const outFile = path.join(dir, `nebari-sandbox-${label}.out`)
  const envFile = path.join(dir, `nebari-sandbox-${label}.env`)
  fs.writeFileSync(outFile, '')
  fs.writeFileSync(envFile, '')
  await exec.exec('bash', [path.join(actionRoot(), 'scripts', script)], {
    env: cleanEnv({ ...extraEnv, GITHUB_OUTPUT: outFile, GITHUB_ENV: envFile })
  })
  return { outputs: parseKeyVals(outFile), envs: parseKeyVals(envFile) }
}

async function runPython(
  script: string,
  extraEnv: Record<string, string>
): Promise<void> {
  await exec.exec('python3', [path.join(actionRoot(), 'scripts', script)], {
    env: cleanEnv(extraEnv)
  })
}

const EXTRACT_OUTPUTS = [
  'keycloak-admin-password',
  'keycloak-realm-admin-password',
  'argocd-admin-password',
  'gateway-ip',
  'keycloak-issuer-url',
  'domain'
]

async function deploy(): Promise<void> {
  const clusterName = core.getInput('cluster-name') || 'nebari-test'
  const nicConfig = core.getInput('nic-config')
  // Validate the boolean inputs up front so a malformed value fails in seconds,
  // before any cluster is created. `destroy` in particular must fail closed.
  const inClusterDns = core.getBooleanInput('in-cluster-dns')
  const resourceSummary = core.getBooleanInput('resource-summary')
  const timingReport = core.getBooleanInput('timing-report')
  const destroy = core.getBooleanInput('destroy')

  // 1. Acquire nic.
  await runStep('install-nic', 'install-nic.sh', {
    NIC_VERSION: core.getInput('nic-version'),
    NIC_BINARY: core.getInput('nic-binary'),
    GITHUB_TOKEN: core.getInput('token') || process.env.GITHUB_TOKEN || ''
  })

  // Stash teardown state before the deploy so the post step can destroy a
  // partially created deployment even if `nic deploy` fails mid-way. The
  // config path is derived the same way deploy-platform.sh derives it.
  const configPath = nicConfig
    ? path.resolve(nicConfig)
    : `/tmp/nic-config-${clusterName}.yaml`
  core.saveState('configPath', configPath)
  core.saveState('destroy', destroy ? 'true' : 'false')
  core.saveState('deployStarted', 'true')

  // 2. Deploy: NIC provisions the kind cluster, MetalLB, and the gitops repo.
  const { outputs: dep } = await runStep('deploy', 'deploy-platform.sh', {
    CLUSTER_NAME: clusterName,
    NIC_CONFIG: nicConfig,
    NEBARI_TIMING_REPORT: timingReport ? 'true' : 'false'
  })
  const kubeconfig = dep['kubeconfig'] ?? ''
  const gitopsDir = dep['gitops-dir'] ?? ''
  core.setOutput('kubeconfig', kubeconfig)
  core.setOutput('cluster-name', dep['cluster-name'] ?? clusterName)
  core.setOutput('gitops-dir', gitopsDir)
  if (kubeconfig) {
    process.env.KUBECONFIG = kubeconfig
    core.exportVariable('KUBECONFIG', kubeconfig)
  }

  // 3. Extract platform outputs (passwords, gateway IP, issuer URL, domain).
  const { outputs: ex } = await runStep('extract-outputs', 'extract-outputs.sh', {
    GITOPS_DIR: gitopsDir
  })
  for (const k of EXTRACT_OUTPUTS) core.setOutput(k, ex[k] ?? '')

  // 4. Wait for the foundational stack to converge.
  await runStep('wait', 'wait-platform.sh', { AWAIT_TIMEOUT: '300' })

  // 5. In-cluster DNS so pods can reach the external Keycloak issuer (#69).
  //
  // After the wait, deliberately. The feature exists for CONSUMER pods doing
  // server-side OIDC, and those cannot exist until this action returns, so
  // there is nothing to gain by doing it earlier -- and two things to lose:
  // MetalLB may not have assigned the gateway address yet (the script used to
  // carry its own LoadBalancer polling loop to paper over that), and bouncing
  // CoreDNS mid-convergence turns any DNS problem into an unrelated-looking
  // ArgoCD or Keycloak failure. wait-platform does not cover kube-system, so
  // running it first verified nothing about CoreDNS either.
  if (inClusterDns) {
    await runStep('dns', 'setup-in-cluster-dns.sh', {
      DOMAIN: ex['domain'] ?? '',
      GATEWAY_IP: ex['gateway-ip'] ?? ''
    })
  }

  // 6. Publish the gateway CA (runner file + in-cluster ConfigMap).
  const { outputs: ca } = await runStep('publish-ca', 'publish-ca.sh', {
    CLUSTER_NAME: clusterName
  })
  core.setOutput('ca-cert-path', ca['ca-cert-path'] ?? '')

  // 7. Optional timing / resource-summary reports.
  if (timingReport)
    await runPython('collect-deploy-timings.py', { CLUSTER_NAME: clusterName })
  if (resourceSummary) await runPython('resource-summary.py', {})
  if (timingReport)
    await runPython('timing-report.py', { CLUSTER_NAME: clusterName })
}

/**
 * Main step: acquire nic, deploy the platform via NIC's local (kind) provider,
 * export KUBECONFIG, and surface the platform outputs. Teardown happens in the
 * post step (post.ts).
 */
export async function run(): Promise<void> {
  try {
    await deploy()
  } catch (err) {
    core.setFailed(err instanceof Error ? err.message : String(err))
  }
}
