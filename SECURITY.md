# Security Policy

## Supported Versions

Security fixes are made on `main` and shipped in the next release. Only the most recent release receives fixes; older releases are not patched. If you can, please confirm the issue against the latest release or `main` before reporting.

## Reporting a Vulnerability

Please do not report security vulnerabilities through public GitHub issues, pull requests, or discussions.

Report them privately through GitHub's private vulnerability reporting: [open a new advisory](https://github.com/nebari-dev/action-nebari-sandbox/security/advisories/new). Only the maintainers can see the report.

Please include as much of the following as you can:

- The version of this action you are running, and where it is deployed
- Steps to reproduce, or a proof of concept
- The impact as you understand it, including what an attacker would need to exploit it

## What to Expect

The maintainers will acknowledge the report, work with you to confirm and understand the issue, and keep you updated on progress toward a fix. Once a fix is released, we will publish a GitHub Security Advisory and credit you unless you ask us not to.

Please give us a reasonable chance to release a fix before disclosing the issue publicly.

## Scope

In scope:

- The action's code, including how it handles inputs, credentials, and outputs
- The sandbox cluster configuration the action creates

Out of scope here:

- Vulnerabilities in the `nic` CLI itself; report those to [Nebari Infrastructure Core](https://github.com/nebari-dev/nebari-infrastructure-core/security/advisories/new)
- Vulnerabilities in kind or other upstream tools the action runs, unless the issue is caused by how the action uses them
- Issues that require an attacker to already hold cluster-admin or cloud-account administrator credentials
