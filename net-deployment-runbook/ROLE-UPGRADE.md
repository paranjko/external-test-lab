# HOST UPGRADE: independent 0.2.14 to 0.2.15 operation

Each Host operator prepares and watches only the Host they own. The operator
uses their existing `GDC_HOME`, private keyring, and SSH alias; no central
worker receives access to every Host.

After a passed immutable governance proposal is published, run:

```bash
gdc --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>
gdc --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>
```

`prepare` verifies the current Genesis, passed proposal, target URLs, and
SHA-256 values before caching the two pinned archives on that Host. It rejects
an activation height less than the profile-defined 60-block safety margin.

`watch` resumes the same immutable proposal only. It records `PREPARED`,
`WAITING_HEIGHT`, `ACTIVATED`, `SYNCED`, `VALIDATOR_EFFECTIVE`, or `FAILED` in
the operator-owned state. A timeout is `INCONCLUSIVE`; it never creates a new
proposal, Genesis, participant, validator identity, or target artifact.

After all five operators have independently produced `VALIDATOR_EFFECTIVE`, a
public observer verifies preservation and the post-upgrade lifecycle:

```bash
gdc --release v2026.08.06 network upgrade verify <proposal-id>
```

That command requires the current pre-upgrade network-verification receipt,
unchanged Genesis lineage, five pinned `0.2.15` public runtimes, the
post-upgrade confirmation-PoC protection window, and a new complete
network-verification result. It is not a substitute for an operator's own
`prepare`/`watch` receipt.
