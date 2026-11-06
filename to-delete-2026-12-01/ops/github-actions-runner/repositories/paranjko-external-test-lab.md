# Repository onboarding record – `paranjko/external-test-lab`

| Field | Value |
|---|---|
| Scope | Repository only; no organization runner group |
| Runner name | `external-test-lab-gdc-node4` |
| Labels | `self-hosted`, `linux`, `x64`, `gdc-node4` |
| Eligible events | Protected default-branch push and approved default-branch manual runbook dispatch; read-only default-branch candidate-build request |
| Excluded events | Every pull request, `pull_request_target`, candidate publication, Docker/DinD, package, OIDC, attestation, release, and repository-write work |
| Token permissions | `contents: read` only |
| Secrets | None; `gdc-node4-runner` environment has no secrets |
| Isolation | Dedicated no-login account, no sudo, privileged groups, Docker socket, operator homes, or writable DevNet paths |
| Routing control | Repository variable `GDC_NODE4_RUNNER_ENABLED`; unset or non-`true` means GitHub-hosted |
| Removal owner | Repository administrator after routing is disabled and the runner is drained |

This record is an allowlist entry, not authorization to install, register, or route work.
