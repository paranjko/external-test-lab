# GDC Node4 repository-scoped GitHub Actions runner

This directory is the credential-free implementation for one repository runner:

| Property | Value |
|---|---|
| Repository scope | `paranjko/external-test-lab` only |
| Runner name | `external-test-lab-gdc-node4` |
| Installation path | `/srv/actions-runner/external-test-lab` |
| Required labels | `self-hosted`, `linux`, `x64`, `gdc-node4` |
| Account | `github-actions-runner`, no login shell, sudo, privileged groups, or Docker socket |
| Enable control | Repository variable `GDC_NODE4_RUNNER_ENABLED`; only literal `true` enables Node4 routing |

## Non-negotiable gate

Do not run `install.sh`, `register.sh`, or start the service until all of the
following are independently approved: reviewed-code enforcement on `main`,
CODEOWNERS for workflow and runner assets, the protected `gdc-node4-runner`
environment with no secrets, Node4 containment, and the owner-authorized
GitHub/host mutation. A GitHub environment approval does not isolate the host.

Public pull requests always use GitHub-hosted runners. Candidate publication,
Docker/DinD, OIDC, package, attestation, release, and write-permission jobs are
permanently GitHub-hosted. The policy checker enforces this contract.

## Operator sequence after the gate opens

1. Verify the committed release/checksum values in `runner-manifest.env` against
   the official release notes.
2. Run `install.sh` as root. It creates the restricted account and verified
   payload but does not register or start the runner.
3. With shell tracing disabled, export a fresh one-time token only for
   `register.sh`; immediately unset it after the command. Do not save or print
   the token. The upstream runner CLI requires its token argument transiently.
4. Start `github-actions-runner-external-test-lab.service`, run `status.sh`, and
   verify the exact repository runner name and labels in GitHub.
5. Keep routing disabled for the hosted fallback proof. Enable it only for the
   approved trusted canaries, then prove restart, cleanup, PR exclusion,
   publication exclusion, and rollback.

## Lifecycle commands

All commands are exact-path guarded and fail on symlinks. `drain.sh` stops the
service; disable routing first. `cleanup.sh --yes` removes only the immediate
runner workspace entries. `update.sh` requires a stopped, registered runner and
keeps a local rollback payload. `rollback.sh --yes` restores that payload only
while stopped. `remove.sh --yes` requires a fresh removal token and removes only
this registered runner and its service payload.

## Local verification

```bash
python3 ops/github-actions-runner/check-workflow-policy.py .github/workflows
ops/github-actions-runner/tests/test-workflow-policy.sh
systemd-analyze verify ops/github-actions-runner/github-actions-runner-external-test-lab.service
```

The Node4 ShellCheck adapter validates the same sorted `.sh` inventory and the
same `--external-sources --severity=warning` options as the Docker Make target,
using the checksum-pinned native binary installed at the runner path.
