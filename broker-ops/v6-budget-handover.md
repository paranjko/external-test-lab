# Replacement-gated operator settlement

The optional `--settle-after-replacement` flag on `v6-budget-rotation.py`
changes the retirement schedule, not the funding allowance. Existing service
installation and the default schedule remain unchanged. This mode requires
qualification on the selected gateway before deployment; unit fixtures alone
do not establish real replacement service or successful settlement.

The frozen chain source prunes escrow data at an age of two epochs. Waiting
until that age to start settlement can collide with pruning. The optional
schedule considers the previous epoch only after the current epoch has a
confirmed funding reservation. If no replacement has been funded, creation
remains reachable without first retiring the old runtime.

The gateway's latest epoch is not always the effective epoch used by chain
creation. In this mode, new funding waits until the parent current epoch group's
effective epoch equals the gateway epoch. Every unresolved funded record and the
newly created escrow must have a matching chain ID, amount and creation epoch.
A post-create mismatch preserves the full debit and successful creation response,
then halts; it never relabels the historical ledger or retries creation. Existing
records made under the older schedule may require explicit reconciliation before
activation. The additional chain GET receives no gateway admin credential.

Before a non-forced settlement, the operator requires:

- A different replacement ID with matching model and explicit active runtime,
  positive balance, no hold and no blocked requests.
- Positive replacement-specific capacity, positive routable model weight and
  positive effective model request limits. Token limits must either have a
  positive configured and effective cap, or explicitly report zero for both
  (the native unlimited configuration). A positive baseline scaled to zero,
  missing fields or malformed values refuse retirement.
- Existing, unsettled chain records for both IDs with matching epoch and amount.
- An inference window with confirmation inactive, completed or absent (never
  generation, grace, validation or an unknown phase), and at least
  fifteen blocks before the switch, rechecked in the same epoch immediately
  before persisting settlement intent.

These are admission observations, not a guarantee against subsequent network
failure. Keep native rotation disabled and verify actual replacement completion
in the isolated and live qualification. Non-forced settlement itself closes old
runtime admission, including when it returns busy; it is not a read-only probe.

Older unresolved escrow records fail closed for explicit reconciliation. Missing
chain records are never silently called settled, refunded or retried. Historical
gross debits, unknown outcomes, bounded busy attempts and durable intent survive
restarts. Do not reset the ledger to activate this mode or combine it with a
second creation owner. Stop the existing timer and wait for an active invocation
before an approved configuration change; preserve its original command for
rollback. The installer enables this flag only when explicitly requested; it
never starts or enables the timer. For an existing differing drop-in, inspect its
complete contents and pass its SHA256 through `--expected-dropin-sha256` together
with `--settle-after-replacement`. A mismatching digest refuses replacement.
The exact original bytes are retained in a mode0600 `.preimage-<sha256>` file
beside the drop-in (not a loaded `.conf` file). The old content-addressed script,
base service/timer and ledger remain unchanged. Verify the loaded command,
reconcile historical rows, and qualify the selected runtime before explicit
timer activation. Rollback requires stopping the timer, waiting for the service
to become inactive, restoring the reviewed preimage and reloading systemd;
never restore an older ledger or discard newer reservations.

## Explicit recovery of a chain-absent runtime

This is a separate operator action, not an automatic retirement rule. An absent
chain record is not proof of settlement or a refund. Do not retry settlement,
recreate the reservation, delete the runtime record or reset the ledger.

1. Stop the selected campaign timer and wait until its service is inactive or
   failed. Confirm native gateway rotation is disabled. Record the exact script,
   gateway identity, ledger binding, original successful funding response,
   escrow ID and gross reserved amount. Unknown funding outcomes require their
   own reconciliation and must not use this procedure.
2. Hold the campaign's existing `lock` exclusively while inspecting and changing
   the selected runtime. Verify its original epoch is at least two epochs old.
   Query the parent chain's
   `/productscience/inference/inference/devshard_escrow/{id}` and require an
   explicit `found: false`; a timeout, error or missing field is not absence.
   Do not send gateway credentials to the parent-chain endpoint.
3. Find exactly that runtime in authenticated `GET /v1/admin/state`. If active,
   require `GET /v1/admin/devshards/{id}/participants` to report zero
   `active_requests`, recheck chain absence, then invoke the native authenticated
   `POST /v1/admin/devshards/{id}/deactivate` with an empty JSON object.
   Never substitute DELETE or forced settlement. Native deactivation closes new
   admission while preserving the stored record and draining requests that race
   with the observation. Check the response identity and `active: false`, then
   verify inactive state with a fresh admin-state readback.
4. Release the lock before invoking the installed operator with its instance
   argument and `--defer-pruned ID`; that command acquires the same lock itself.
   It must independently verify absence/inactivity before appending the no-retry
   disposition. A refusal is a stop condition, not permission to edit SQLite.
5. Verify the original funding row, failed attempts and full gross reservation
   remain. Keep the timer stopped until all unresolved records and the loaded
   replacement command have been checked. Resume only under the applicable
   funding authorization, then verify actual JSON/SSE and epoch handover.

Use only the selected gateway's existing private admin credential. Do not put
credentials into shared instructions, shell history or evidence. Preserve the
failed observations and the separate recovery receipt; successful deactivation
does not establish successful settlement or continuous inference availability.

Step 3 is available as a guarded operator command (A example; select B/node0
and its own receipt path for B):

```sh
ssh gdc-node4 python3 - a --deactivate-pruned ESCROW_ID \
  --receipt /srv/dai/broker-tests/v6-a/pruned-runtime-receipt.json \
  < broker-ops/v6-budget-rotation.py
```

Use the verified numeric ID and a new receipt path. The command requires a
paused timer, takes the existing campaign lock, checks confirmed funding,
staleness, native-rotation disablement, zero active requests and chain absence
twice. It only deactivates admission, then checks inactive state; it does not
write the ledger, settle, refund or fund. A failed response has an uncertain
outcome: inspect the receipt and runtime before retrying. Run the separate
`--defer-pruned` step only after successful inactive readback.

Run `make -C broker-ops test-v6-budget-rotation` for the logic and existing service
fixture checks. A subsequent exact-source full gate and runtime handover proof
remain required before using this optional schedule on the stand.
