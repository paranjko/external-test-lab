# Daily bootstrap monitoring

The `Network bootstrap monitor` workflow checks published bootstraps every day
at 07:17 UTC. The schedule starts after the workflow is merged into the default
branch. GitHub may delay scheduled runs; this is not a real-time availability
monitor. Use **Run workflow** for an extra check.

Every `*.json` filename directly in `bootstrap/` selects a network at
`https://gonka-dev.net/<chain_id>/bootstrap.json`. Adding a release descriptor
automatically adds that network to monitoring. The check reads the published
document and compares it with the repository copy; an unpublished network or
undelivered update fails the check. Examples in subdirectories are not networks.

## Checks

- Strict JSON and the published bootstrap schema, including optional fields
  supported by that schema
- Bootstrap chain ID matches the selected network
- Published JSON and ENV bytes match the current repository files
- Every seed's RPC reports the declared node ID and chain ID
- Every seed serves a genesis with the declared SHA-256 and chain ID
- Every seed's P2P TCP port accepts a connection
- Every declared seed API serves a JSON participants array
- Block progression and synchronization state for each seed
- Pinned software image digests and supported platform manifests, when declared

The genesis hash uses the exact `result.genesis` JSON bytes returned by RPC,
matching `inferenced download-genesis`; it does not reformat the genesis.
The check does not require an installed `inferenced` binary. HTTP requests and
TCP connections have timeouts and at most two attempts. Redirects are refused.
One failing seed does not skip the remaining checks or networks.

This checks bootstrap correctness, current block progression, endpoint and
image-manifest availability, not validator membership, inference, broker health
or successful deployment. A failure may be a temporary outage rather than a stale file;
inspect the report before changing the bootstrap. The monitor never changes
nodes, bootstraps or network parameters.

## Telegram notifications

The separate notification job uses the existing GitHub Environment
`telgram_gonka_dev_bot` with:

- Secret `GDC_TELEGRAM_BOT_TOKEN`
- Variable `GDC_TELEGRAM_NOTIFICATION` containing the target chat ID

For unattended delivery, the Environment must allow this workflow to run
without required-reviewer approval. Removing that protection is a repository
administrator decision; adding this workflow does not change the protection.

On failure, Telegram receives one HTML message per failed network, with links
to its bootstrap and the GitHub Actions run. Healthy networks produce no
messages. JSON serialization and HTML escaping preserve chat IDs and links.
The token is available only to the notification step and is not written to the
report or logs. Telegram errors fail the notification job. A POST is not retried
because a lost response could otherwise cause duplicate messages.

The check job runs without Telegram credentials or Environment approval. Its
native JSON report lists each check; `bootstrap-monitor-<chain_id>` artifacts
retain per-network results for 30 days. The matrix does not cancel other networks
on failure. Installation/invocation failures are recorded as execution failures,
not successful validation. No Python validator runs in the monitor.

## Run locally

Install through the same public user path consumed by CI:

```bash
curl -LsSf https://gonka-dev.net/ctl/install.sh | sh
gonkactl bootstrap validate gonka-devnet-community --compare-published bootstrap --json
```

The CLI performs read-only requests and prints its JSON report. It does not
send Telegram messages. Exit codes are `0` for success, `1` for failed checks
and `2` for invalid inputs or local execution errors.

The local composite Action `.github/actions/gonkactl-bootstrap` accepts a
`chain-id`, `inventory`, `report`, `timeout` and `origin`. It downloads the public
installer, selects immutable alpha.3 and verifies the installed source commit.
Its Make targets only install, invoke the CLI and transport reports/notifications;
they do not implement network validation. The existing Go bootstrap and installed
CLI tests cover schema, raw Genesis, endpoints, image manifests and publication.

The Action Makefile's `notify` target is a separate, explicit send operation. It requires
the two Telegram variables, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID` and a report
from the check. CI supplies this context automatically. Do not test it against
a real chat with synthetic failures.

References: [GitHub scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule),
[Telegram sendMessage](https://core.telegram.org/bots/api#sendmessage)
