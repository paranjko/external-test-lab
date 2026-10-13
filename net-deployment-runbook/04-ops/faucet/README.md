# Telegram faucet: durable administration and user allowance

The private Telegram faucet is closed on a fresh store, administrators control funding without changing inference or the separate gateway-reserve service

The default allowance is `100 GNK` per actual Telegram user across all recipient addresses in a rolling `24 hours`, `1 GNK = 1000000000 ngonka`, monetary accounting uses integers

## Managed deployment

Use the existing network-owner GDC state, account and Genesis, configure approved positive numeric administrator IDs in `GDC_FAUCET_INITIAL_ADMINS_JSON` in the private `$GDC_HOME/.env`, never publish that inventory or substitute a chat ID for a user ID

After the exact revision has passed required checks, independent acceptance and the applicable rollout approval, run from the runbook directory

```bash
./gdc.sh ops faucet
./gdc.sh ops consumer telegram apply
./gdc.sh ops consumer telegram status
```

`ops faucet` is the complete faucet command, it does not accept an `apply` argument

This command reconciles the existing faucet reserve and signer deployment, it is a mutating operation rather than a read-only preview, do not run it only to inspect policy

`ops consumer telegram apply` also redeploys the existing consumer and verifies real inference, an inference failure does not establish failure of the independently implemented faucet policy

Keep signer credentials on the faucet Host, the bot receives only its separate capability token, do not put tokens, keyrings, recipient addresses or raw private receipts in GitHub evidence

The managed state directory `/srv/dai/gonka-devnet-faucet/data` is mounted at `/data`, preserve `faucet.sqlite3` and its SQLite sidecars across restart or replacement, do not remove the store to recover a failed request or reapply bootstrap

Administrator bootstrap applies only to a fresh policy store, later environment changes do not re-add a removed administrator or overwrite durable open/closed state and limits

## Private commands

Send new direct messages to the existing bot, forwarded messages and group commands cannot administer or fund this faucet

| Command | Who can use it | Result |
|---|---|---|
| `/faucet status` | Any actual user | Own remaining allowance, accounting, next eligibility and chain service observation status |
| `/admins list` | Administrator | Current numeric administrator IDs |
| `/admins add <numeric ID>` | Administrator | Add a durable administrator |
| `/admins remove <numeric ID>` | Administrator | Remove a durable administrator, removing the last administrator is rejected |
| `/faucet open` | Administrator | Permit new user reservations and dispatch |
| `/faucet close` | Administrator | Refuse new dispatch, an already executing signer finishes before close is acknowledged |
| `/faucet limit <positive GNK> [24h]` | Administrator | Change the durable rolling amount, the window remains fixed at `24 hours` |
| `/faucet <Gonka address>` | Any actual user while open | Request the remaining available amount, subject to the separate anti-spam bound |

`/faucet list`, `/faucet add <numeric ID>` and `/faucet remove <numeric ID>` are equivalent administration aliases

Limits accept up to nine decimal places without floating-point conversion, for example `/faucet limit 100.000000001`, zero, negative values, exponent notation and values outside the bounded SQLite integer range are rejected

Actual changes record actor, time and before/after policy in private `faucet_policy_events`, repeated no-change controls do not add duplicate audit events

`GDC_FAUCET_TELEGRAM_MAX_CLAIMS_PER_USER` is a separate anti-spam bound, default `1` request per rolling day, failed or cancelled attempts can still count toward anti-spam even when their monetary reservation is released

`GDC_FAUCET_CLAIM_NGONKA` and `GDC_FAUCET_WINDOW_SECONDS` configure the ordinary public claim path, they do not replace the durable Telegram monetary policy or its fixed `24-hour` window

## Retry and accounting

A Telegram update creates one durable intent before signing, replaying the same update returns the stored amount and receipt rather than sending again, reusing an intent for another user or address is rejected

Pending, uncertain and submitted intents keep reserving allowance even after `24 hours`, unavailable chain readback never releases their reservation, a crash or delivery timeout is not permission to rebroadcast

Successful settlement requires matching transaction hash, numeric success code and an observed chain block timestamp, the rolling allowance expires relative to that verified timestamp rather than the request or observation clock

Only definite rejection, observed chain failure or cancellation before signing releases a reservation, reconciliation checks at most one prior hash per request and advances a durable fair cursor so an unavailable older hash cannot starve newer receipts

Unknown migrated amounts remain unavailable until evidenced reconciliation, do not assume an unresolved legacy reservation expires automatically, preserve the original database and obtain the missing receipt through the approved operator workflow

`/faucet status` reports only the caller's allowance, `chain_service_state=unverified` is not a readiness claim, administrator IDs are returned only through administrator controls

## Local checks and live proof

Run the named local policy and actual localhost restart checks from the repository root

```bash
make -C net-deployment-runbook test-faucet-policy test-faucet-policy-http
python3 net-deployment-runbook/scripts/test-telegram-bot.py
```

The HTTP test uses temporary state and a synthetic signer, it does not send GNK or contact Telegram, the bot test is also local and needs permission to bind a localhost socket

Before publication, run the repository-required complete suite from a clean source snapshot with an empty HOME and no inherited GDC state, local developer results do not replace that gate

Live acceptance separately requires the approved private chat, a fresh valid address, the accepted deployed revision and actual chain balance/transaction readback, retain before/after balances, the settled hash and block timestamp privately, publish only sanitized outcomes

Policy commands never enter model prompts, this user allowance does not limit independently authorized operator gateway funding

See the [Telegram consumer](../../scripts/telegram-bot/README.md), [OPS role](../../ROLE-OPS.md), [implementation](faucet.py), [policy tests](../../scripts/test-faucet-policy.py) and [HTTP lifecycle tests](../../scripts/test-faucet-policy-http.py)
