# Two-gateway DevShard qualification

This workflow separates offline preparation, isolated artifact qualification,
and explicitly authorized network operations. A rendered document does not
prove deployment, recovery, or successful legacy retirement.

## Whole-params governance preview

Capture the complete fresh inference params response through the existing
operator query path. Retain it outside the checkout. Review its chain identity
and full contents before binding its hash. These commands only read local
JSON and print a preview; they never use a wallet, contact a node, sign, or
broadcast a transaction.

```bash
python3 net-deployment-runbook/scripts/devshard-preview.py hash \
  --params /private/evidence/params.json
python3 net-deployment-runbook/scripts/devshard-preview.py activate \
  --params /private/evidence/params.json \
  --expected-sha256 REVIEWED_FULL_PARAMS_HASH \
  --creator VALIDATED_A_ADDRESS --creator VALIDATED_B_ADDRESS
```

Replace the uppercase arguments with the reviewed values. Creator bindings
must be distinct lowercase Gonka account addresses with valid checksums.
An empty current creator list is permissionless policy; this command refuses
to silently change it into a restrictive allowlist.

The preview includes the full desired params, a semantic delta, the original
params hash, the desired hash, and the complete `MsgUpdateParams` message.
Activation changes only the v5 URL/hash to official 5.0.2 and appends the two
creators. Existing creators, legacy versions, unknown fields, and unrelated
params remain intact. Duplicate JSON fields, duplicate version names,
duplicate creators, missing bindings, and a stale preimage are errors.

Use `recover` instead of `activate`, without creator arguments, to preview
the official 5.0.1 mapping. This is conditional recovery, not restoration of
the old 5.0.0 binary. Require isolated post-upgrade state/nonce recovery proof
before any live use. Use `retire` to preview removal of exactly v3/v4 while
preserving every creator, v5, and other version. Actual retirement additionally
requires accepted v5 service, migrated or explicitly stopped clients, terminal
legacy escrows and a consistent checksum-bound inactive archive. Remove only
the approved services, routes, approvals and automatic-start references; verify
their absence and repeat a small A/B inference and chain-health check. This
bounded retirement does not require an old-runtime restore rehearsal.

Preview generation does not assert those operational prerequisites. There is
no `--apply` option. Before any separately authorized governance operation,
fetch the complete params again and reject drift from the reviewed preimage.
Never replay an old full document over concurrent parameter changes. The
hashes use the existing GDC `jq -cS` snapshot contract. For activation/recovery,
the messages and their hashes are compatible with
`verify-devshard-governance-snapshot.sh`; retirement needs its own reviewed
removal scope rather than bypassing the existing no-revocation guard.

## Instance rendering and settings

Use an operator-owned design document with `gateway_image`, `platform`,
`gateway_common_env`, and exactly two `gateways` entries identified as A/B.
Each entry binds its project, `gateway` service, dedicated directory below
`/srv/dai/broker-tests/`, named volume, external private bridge, validated
creator address, and loopback API/accounting port mappings. The renderer
enforces the pinned gateway and v5 environment contract; it rejects inherited
database bindings and duplicate resources even when hosts differ.

```bash
python3 net-deployment-runbook/04-ops/devshard-instances.py \
  --design /private/operator/two-gateways.json \
  --secret-a /private/operator/a/gateway.env \
  --secret-b /private/operator/b/gateway.env
```

Each secret file must have mode 0600 in a mode-0700 directory and contain only
literal `DEVSHARD_PRIVATE_KEY`, `DEVSHARD_ADMIN_API_KEY` and
`DEVSHARD_API_KEYS` assignments. A/B keys must differ. No secret values appear
in renderer output. Output is a JSON object mapping A/B to separate Compose
documents; inspect each with `docker compose config` in a private environment.
That Docker command expands secret files, so never publish its raw output.
The secret file paths must exist on the host where Compose runs.

Rendering does not start services or prove that a named Docker volume is new.
Fresh-volume inspection and ownership-bound lifecycle checks must precede the
first start; an existing unowned volume is not safe merely because rendering
succeeds. Reuse after a verified restart is distinct from fresh creation.

The settings transform selects the model by `model_id`, verifies it against
the supplied fresh catalog, and preserves the complete object. Only the
default model, selected model's `access_mode`, and the two rotation flags
change. When a fresh image omits the selected model's limits entry, the client
materializes it using the current global concurrency/input limits before
setting access mode; it never substitutes arbitrary or zero-filled limits.
A missing catalog model or duplicate settings entry fails closed. The companion settings
client performs authenticated loopback HTTP read/modify/write/readback with an
instance lock. Preview first:

```bash
python3 net-deployment-runbook/04-ops/devshard-settings.py \
  --port 18087 --secret-file /private/operator/a/gateway.env \
  --model Qwen/Qwen3-0.6B --evidence /private/evidence/settings-preview
```

After reviewing the complete delta and obtaining authority for that gateway,
repeat with a new evidence directory, `--apply` and
`--expected-sha256` set to the preview's `before_sha256`. It re-reads settings
before POST, refuses drift, preserves the full response, and requires exact
readback. Auth is passed to curl over stdin, not command arguments. Neither
uncertain POST nor a failed readback triggers a retry or blind restore.
Evidence directories are exclusive, mode 0700, with mode-0600 immutable
numbered records. Keep them private; gateway settings may contain internal
endpoints. Persisted restart proof remains a separate runtime gate.

## Offline checks

```bash
make -C net-deployment-runbook test-devshard-two-gateways
```

Current coverage: full-params activation/recovery/retirement preservation,
preimage drift, invalid bindings, duplicate input, CLI refusal of apply,
interoperability with the existing snapshot verifier, actual Compose config
rendering, A/B resource and secret separation, private listeners, Mainnet and
inherited-state refusal, full-settings HTTP preservation, stale-preimage and
concurrent drift refusal, overlap locking, and uncertain POST handling. These checks are
not artifact, inference, migration, restart, or live acceptance results.

## Workload schedule and accounting engine

The public document-QA corpus and its wire hashes are checked in under
`net-deployment-runbook/data/devshard-workload/`. The corpus includes source
revision, attribution and modification notice; the repository's Apache-2.0
`LICENSE` applies. Its Mainnet examples are input text, never endpoint defaults.
Preview one complete schedule without network access:

```bash
python3 net-deployment-runbook/04-ops/devshard-workload.py --preview-run 1
make -C net-deployment-runbook test-devshard-workload
```

Contract `gdc-devshard-workload/3` has twenty requests per gateway per run,
with ten streaming and ten non-streaming requests. Even pairs send A then B;
odd pairs send B then A. Run 2 repeats the same case order with distinct IDs
and reverses the response mode for each case. That is eighty positive requests
across both gateways and both runs. The first journal record freezes the full
versioned schedule, payload hashes and safety limits before any dispatch;
reopening refuses a different execution contract without rewriting old results.
The engine verifies all forty historical UTF-8 payload hashes before applying
the version-3 streaming-only `stream_options.include_usage=true` opt-in. The
official gateway otherwise omits final SSE usage. Corpus, non-stream payloads,
schedule and limits are unchanged; the new execution manifest binds the new
streaming wire hashes. Old journals and the historical sizing manifest are
never rewritten, and reopening a different contract is refused.
It does not send expected answers or factual-review checklists to the model.

The Python engine accepts bounded observation and transport adapters. There is
currently no network-execution CLI: the preview and fake-clock tests do not
prove a connected workload. A production adapter must bind fresh chain/epoch,
cPoC, the minimum of twenty recent block intervals, creator/model/protocol and
actual artifact identity, context capacity, current escrow nonce/balance and
source-supported per-request spend/nonce reservations. It must verify these
facts, not populate a readiness document from configuration alone. The
existing public admission observer intentionally omits the private accounting
fields and is not sufficient by itself.

`04-ops/devshard-transport.py` supplies the private HTTP transport. Its A/B
bindings use distinct literal loopback or RFC1918 IPv4 addresses and explicit
ports, plus the existing mode-0600 instance secret files. It uses a client key
only for completion POSTs and an admin key only for the three read-only
settings/models/devshards observations. It does not follow redirects, use
environment proxies, resolve arbitrary DNS, retry or mutate admin settings.
Use an approved private route or operator tunnel; this is not public ingress.

The transport caps connect time at five seconds, each request at sixty seconds
and response retention at one MiB plus the byte that proves overflow. An
absolute socket-interruption timer also bounds trickling HTTP headers. It
retains partial body/status/error evidence on transport failure and records
TTFT at the first complete SSE event with nonempty text, not at HTTP headers
or a role-only event. The engine journals that receipt before rejecting an
incomplete transport outcome. No credentials appear in returned receipts.
Failed HTTP or JSON observations raise `ObservationError` with a `receipt`
containing the gateway, path and raw transport result; collectors must journal
that receipt before stopping, rather than discard the failed read.
The chain/runtime observation collector and connected execution CLI remain
unfinished; this transport alone is not RUN-01 acceptance.

`Campaign` takes one persistent private directory and the two instance lock
paths. Store those locks beside each instance's private operator files. The
locks retain the campaign binding after process exit; a new evidence directory
cannot reset lifetime accounting. Do not delete the binding or journal to
retry a failed measurement. Both runs and separately admitted smoke share
the sixty-attempt and sixteen-escrow limit per gateway. The ledger is mode 0600,
append-only JSONL with chained hashes and fsync before dispatch. Preserve it
outside disposable worktrees. It contains private observations and responses.

Every admission reserves spend and receives one terminal record. An interrupted
admission without a terminal record blocks reopening for reconciliation; it
never triggers redispatch. Uncertain transport, failed readback or a bounded
drain failure stops the campaign. Unknown spend retains its full reservation.
Full responses are retained before parsing. Valid results must correlate the
response ID to the selected escrow and advancing nonce, preserve identity and
stay within the reserved balance delta.

The engine admits only during observed Inference, outside cPoC, with more than
ninety seconds of conservative PoC margin and fresh observations. It requires
one idle slot per gateway, no cleanup in flight, adequate current-epoch capacity,
and both automatic lifecycle flags off. Quiet segments are explicit. Each run
has a four-hour wall deadline, not a minimum duration or a pacing floor.
Observed eligible time is a diagnostic, not a soak requirement. Long unobserved
gaps do not count as eligible time. Request and drain deadlines remain sixty
and ninety seconds respectively; adapters must obey the absolute deadlines.

JSON/SSE checks require the expected model, nonempty output, `stop`, valid
bounded usage, stable correlation and complete SSE termination. Summaries
include latency/TTFT percentiles, throughput and token counts. Automated PASS
does not establish factual answer quality or release acceptance: review the
corpus checklists separately, and retain every anomalous response. The optional
scheduler is not installed or enabled.

## Exact-artifact testenv preparation

The fixture adapter builds only upstream testenv's generator and mock
chain/DAPI/ML helpers from pinned source. It never builds the gateway,
Versiond or DevShard executables. Preparation requires Python 3.12+, Go
compatible with the pinned source, local Docker Compose, the two pinned
runtime images already pulled, and the previously verified release inputs.
Go is optional for the general runbook suite and needed only when building
the fixture helpers. A later preparation can reuse checksum-bound helpers.

```bash
python3 net-deployment-runbook/scripts/devshard-502-fixture.py \
  --source-git /path/to/gonka-reference \
  --root /private/evidence/ds502-fixture-example \
  --archive-502 /private/artifacts/devshardd-5.0.2.zip \
  --two-gateways
```

The output directory must be new; its parent must already exist. Preparation
verifies the official ZIP and executable hashes, generates synthetic keys,
and writes a private Compose document, helper-build receipts and artifact
manifest. Fresh qualification requires no old executable or recovery archive.
The optional `--archive-501` and `--old-500` inputs remain available for existing
historical tests. The old executable is not represented as an official archive.

For old-state transition tests, add `--initial-version 5.0.0-cached`. The
adapter verifies the retained executable and reproduces its exact installation
metadata under Versiond's hash-addressed cache. The mock catalog keeps the
retained archive hash and an unavailable ZIP URL. There is no force-version
or executable override: the pinned supervisor must accept the verified cache.
Record the running child's executable hash before admitting synthetic work.
Later catalog changes use the unchanged official 5.0.2 or 5.0.1 ZIPs.

To reuse already built testenv helpers, replace `--source-git` with
`--helpers-from EXISTING_FIXTURE --helpers-receipt-sha256 REVIEWED_HASH`, where
the hash identifies that fixture's `prepared.json`. The adapter verifies the
pinned source and all four helper hashes before copying them. It generates
fresh synthetic identities and never copies the earlier configuration, keys,
chain state or gateway databases. The new receipt binds its helper provenance
to the original preparation receipt. Keep both receipts and their evidence.

The generated composition removes upstream source-built runtime substitutions,
forced/override versions, HA router and Postgres. Versiond downloads the
unchanged official ZIP from mock DAPI on an internal network and uses SQLite.
Every writable mount is inside the new fixture. Published-port declarations
are loopback-only; Docker internal-network policy may suppress host publishing,
so probes can run from an explicitly owned client container in that network.
Do not attach the fixture to an external network to make a probe convenient.

`--root EXISTING_FIXTURE --render-existing-to NEW_FILENAME` creates a new
single-gateway render while preserving the original receipt and data. Pair
renders are immutable and refuse that option. Preparation starts no container.
No cleanup command is provided: retain synthetic state and logs.

```bash
make -C net-deployment-runbook test-devshard-502-fixture-contract
```

These offline tests check topology, mount and chain containment, official
image selection, removal of overrides, the supervisor/child shutdown budget,
old-cache metadata, helper-reuse integrity, independent pair generation and
one-shot start/create containment. Preparation still reports runtime acceptance
`NOT RUN`; running services alone do not change that verdict.

### Fresh isolated A/B create/use

`--two-gateways` generates three owned projects: shared mock infrastructure
and independent A/B gateway writers. A/B have distinct synthetic private,
admin and client keys, empty registries and separate fresh storage. They share
only the fixture's internal network and mock chain/DAPI/ML. No product binary
is rebuilt, and no earlier database is imported.

Review the private documents and bind the exact `prepared.json` hash:

```bash
python3 net-deployment-runbook/scripts/devshard-502-pair.py \
  --root /private/evidence/ds502-fixture-example \
  --receipt-sha256 REVIEWED_PREPARATION_HASH
```

The default is preview. Add `--start` only for the reviewed local fixture.
Start verifies the seed/composition/helper/archive/image bindings, fresh empty
writer directories, absence of prior projects/network and overlapping writable
mounts. It records a durable exclusive intent before starting infra, A and B.
Any uncertain start requires inspection; rerunning cannot reset or recreate it.
The command uses Docker context `default` and never pulls or builds images.

From an owned client on that internal network, run as the UID owning the
mode-0600 secret files. Mount the runbook read-only at `/runbook`, the exact
fixture at `/fixture`, and the verified official 0.2.15 `inferenced` binary
read-only at `/usr/local/bin/inferenced`. Resolve the current private container
addresses with Docker inspection and use the prepared gateway ports, not
guessed defaults. Substitute those endpoints below:

```bash
python3 /runbook/scripts/devshard-502-exercise.py \
  --root /fixture --gateway-a http://GATEWAY_A_IP:GATEWAY_A_PORT \
  --gateway-b http://GATEWAY_B_IP:GATEWAY_B_PORT \
  --chain-rpc http://MOCK_CHAIN_IP:26657 --chain-grpc MOCK_CHAIN_IP:9090 \
  --inferenced /usr/local/bin/inferenced --create --evidence-name create-use-01
```

Only the isolated fixture chain is accepted. This creates one synthetic
5-GNK escrow per gateway, records intent before the POST, confirms creator,
model and ID through the official read-only gRPC query, and checks registration.
Existing state or a previous create intent prevents another mint, even with a
new evidence directory. No uncertainty triggers a replacement transaction.

Use the same endpoint/mount bindings with `--smoke --evidence-name smoke-01`
instead of `--create`. This applies the complete reviewed settings transform,
sends one frozen corpus request through A as JSON and B as SSE, and checks
response/escrow/nonce/balance plus bounded drain. Smoke shares the persistent
campaign accounting and locks with future workload invocations. It retains
partial HTTP evidence, never resends a recorded request and stops on failure.
Keep failed runs and all later reconciliation separate; never erase a journal
to repeat a measurement. A corrected fresh-identity fixture is a new experiment,
not a passing replacement for the original result.

Mock output proves plumbing and attribution only. These helpers do not prove
real model quality, complete the two-pass workload, or authorize live operations.

## Isolated state capture and recovery clones

`scripts/devshard-502-state.py` operates only inside an existing owned fixture.
It never stops services, changes a catalog, submits a transaction, or restores
over an existing directory. Stop admission, record zero active requests and
pending cleanup, then stop both the gateway and Host within the drain budget.
Keep mock chain running: restarting its in-memory store loses the continuity
boundary even when the generated seed is unchanged.

```bash
python3 net-deployment-runbook/scripts/devshard-502-state.py snapshot \
  --root /private/evidence/ds502-fixture-example \
  --output /private/evidence/ds502-fixture-example/post-work-snapshot
```

The command checks actual container ownership, exact image references,
stopped writers, disabled restart policies, contained mounts, and other
running containers with overlapping writable mounts. It copies the complete
state directories through Docker, including WAL and payload files, and checks
that the writers and mock-chain process did not change during capture. The
manifest records file hashes, SQLite integrity, session nonces, signed diff
bytes and host signatures. SQLite inspection uses a scratch copy, preserving
the captured WAL/SHM bytes. Links, missing files, corrupt databases, journal
gaps, and unsigned diffs are rejected. These checks assume the fixture's
single trusted operator; they do not protect against a concurrent root user.

A nonzero gateway exit is refused by default. For isolated diagnosis only,
`--allow-unclean-gateway` permits copying a stopped gateway's crash state.
The manifest retains its exit code and that explicit option. This is not a
clean-shutdown result or a recovery PASS. Host failure, a running writer,
restart policy or an OOM stop still fails the capture. All copies require
official-runtime replay and client inference before recovery can be accepted.

Use `clone` with `--snapshot`, its reviewed `--sha256`, `--current`, its
`--current-sha256`, `--root`, and a new `--output` directory. The command also
captures fresh stopped state, so a previously valid current receipt cannot
hide later work. A different mock-chain process, changed signed journal or
later nonce prevents restoration of a stale preimage. To recover post-upgrade
state, use the same latest verified snapshot as both source and current.
The unclean-gateway diagnostic option must be explicit again when applicable.

`render-clone` takes `--snapshot` pointing to the prepared clone directory,
`--sha256` of its `clone.json`, the current fixture `--compose`, `--root`, and
a new Compose `--output` filename inside the fixture root. It verifies the
clone and changes only the two state mounts. Retain the original directories;
start only one writer per clone through the reviewed fixture composition.
Catalog mutation and runtime start remain separate explicit operations.

After recovery and a new bounded inference, stop the writers and capture a
second snapshot. `compare` accepts the same source/current paths and hashes;
add `--require-new-work` to require advancing nonces while preserving every
earlier signed diff and host signature. Also compare runtime balance, model,
escrow identity and the actual process executable hash. Byte continuity alone
does not verify signatures cryptographically or prove successful inference.
Preserve failed captures and stale-restore refusals alongside positive results.
