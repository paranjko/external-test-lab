# Independent A/B gateway release switch

This helper supports only the stand's independent, single-volume v6 A/B
Compose layout. It does not replace managed GDC migration commands, update
hosts or governance, or support shared Postgres/HA layouts. Those layouts fail
the preflight. Do not use this command as a generic gateway installer.

Verify the published release checksums, source, protocol and linux/amd64 image
before use. Pull the exact digest on the selected host first. A is on node4;
B is on node0. Inspect the current container image and select the existing
budget campaign; never create a new campaign to bypass its ledger.

Run from the repository root, with the two complete immutable references:

```sh
ssh gdc-node4 python3 - a \
  --expected-image "$CURRENT_IMAGE" --target-image "$VERIFIED_IMAGE" \
  --campaign rotation-10000gnk-20261013 < broker-ops/v6-gateway-release-switch.py
```

This is read-only. For an authorized switch, add `--apply --backup` with a
new absolute path directly inside `/srv/dai/broker-tests/v6-a`. For B use
instance `b`, node0 and a path directly inside `v6-b`. Never reuse a backup.
Credentials are read only on the selected host, not passed on the command line.

The helper saves private preimages, pauses only the selected operator timer,
waits for the operator to finish, takes its campaign lock and checks the ledger.
It deactivates current escrows and waits for zero in-flight requests before
stopping the sole gateway writer and copying its persistent state. It changes
only the Compose image reference, verifies the new runtime and unchanged
settings/storage/ledger, reactivates the prior escrow set, then restores the
timer's previous state. It neither funds nor settles escrows. Traffic may be
unavailable during this exclusive maintenance interval.

Failure after timer stop intentionally leaves rotation paused. Read the private
preimages and live state before recovery; do not blindly retry, force settlement,
or replace the database. `switched.json` records completion before timer restore;
`receipt.json` records completed restoration. A missing receipt is not proof
that no mutation occurred. There is no automatic rollback: establish storage
compatibility and the exact failed phase before restoring the saved Compose
reference through a reviewed recovery operation. Backups can contain secrets;
never publish them.

After replacement, run authenticated JSON/SSE and the issue242 five-minute
scenario in a fresh non-PoC window. Health and image checks alone do not qualify
inference. Apply timeout tuning separately, with its own receipt, only after the
corrected gateway is verified.

Offline verification:

```sh
make -C broker-ops test-v6-gateway-release-switch test-v6-first-token-tuning
```

The isolated fixtures exercise real temporary files and SQLite ledgers, while
all Docker/systemd/API operations are explicit fakes that reject unknown calls.
They are operator-contract checks, not evidence of an executed deployment.
