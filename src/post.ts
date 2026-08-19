/**
 * Post step: destroy the deployment when the job ends, including on failure or
 * cancellation. Skipped when the deploy never started or `destroy: false`.
 */
import * as core from '@actions/core'
import * as exec from '@actions/exec'

async function destroy(): Promise<void> {
  if (core.getState('deployStarted') !== 'true') {
    core.info('Deploy never started; nothing to destroy.')
    return
  }
  if (core.getState('destroy') !== 'true') {
    core.warning('destroy: false - leaving the deployment running.')
    return
  }
  const configPath = core.getState('configPath')
  if (!configPath) {
    core.warning('No saved config path; cannot run nic destroy.')
    return
  }

  await core.group('nic destroy', async () => {
    // --auto-approve: no interactive confirm in CI. --force: continue past
    // individual resource failures so a partial deploy still tears down.
    await exec.exec('nic', [
      'destroy',
      '-f',
      configPath,
      '--auto-approve',
      '--force'
    ])
  })
}

export async function run(): Promise<void> {
  try {
    await destroy()
  } catch (err) {
    core.setFailed(err instanceof Error ? err.message : String(err))
  }
}

run()
