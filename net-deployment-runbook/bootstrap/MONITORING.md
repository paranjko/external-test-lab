# Daily bootstrap monitoring

The `Network bootstrap monitor` workflow checks published bootstraps every day
at 07:17 UTC. The schedule starts after the workflow is merged into the default
branch. GitHub may delay scheduled runs; this is not a real-time availability
monitor. Use **Run workflow** for an extra check.

Every `gonka-*.json` filename in `bootstrap/release/` selects a network at
`https://gonka-dev.net/<chain_id>/bootstrap.json`. Adding a release descriptor
automatically adds that network to monitoring. The check reads the published
document, not the repository copy; an unpublished network fails the check.

## Checks

- Strict JSON and the published bootstrap schema, including optional fields
  supported by that schema
- Bootstrap chain ID matches the selected network
- Every seed's RPC reports the declared node ID and chain ID
- Every seed serves a genesis with the declared SHA-256 and chain ID
- Every seed's P2P TCP port accepts a connection
- Every declared seed API serves a JSON participants array

The genesis hash uses the exact `result.genesis` JSON bytes returned by RPC,
matching `inferenced download-genesis`; it does not reformat the genesis.
The check does not require an installed `inferenced` binary. HTTP requests and
TCP connections have timeouts and at most two attempts. Redirects are refused.
One failing seed does not skip the remaining checks or networks.

This checks bootstrap correctness and endpoint availability, not block
production, validator membership, inference, broker health or software artifact
availability. A failure may be a temporary outage rather than a stale file;
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
log lists each failed check; the `bootstrap-monitor-report` artifact retains
the full per-network results for 30 days. A setup failure before a report exists
fails CI but does not send a misleading bootstrap warning.

## Run locally

With Python 3 and `jsonschema` installed:

```bash
make -C net-deployment-runbook test-bootstrap-monitor
make -C net-deployment-runbook bootstrap-monitor
```

The first command uses local fixtures only. The second performs read-only
requests to the published networks and writes
`net-deployment-runbook/.data/bootstrap-monitor/report.json`. It does **not**
send Telegram messages. Exit codes are `0` for all checks passing, `1` for a
failed bootstrap check and `2` for a configuration or local execution error
(Make itself returns a nonzero status for either failure).

For another inventory or publication origin:

```bash
make -C net-deployment-runbook bootstrap-monitor \
  bootstrap_monitor_release_dir=/path/to/release \
  bootstrap_monitor_base_url=https://example.net \
  bootstrap_monitor_report=/tmp/bootstrap-report.json
```

`bootstrap-monitor-notify` is a separate, explicit send operation. It requires
the two Telegram variables, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID` and a report
from the check. CI supplies this context automatically. Do not test it against
a real chat with synthetic failures.

References: [GitHub scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule),
[Telegram sendMessage](https://core.telegram.org/bots/api#sendmessage)
