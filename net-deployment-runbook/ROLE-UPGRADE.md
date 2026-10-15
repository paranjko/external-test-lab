# HOST UPGRADE

## Update the DevShard supervisor from bootstrap

```bash
gdc host upgrade <ssh-alias>
```

This command downloads and validates
`https://gonka-dev.net/gonka-devnet-community/bootstrap.json`, selects
`software.components.versiond.image`, pulls its pinned digest for
`software.platform`, and recreates only the existing `versiond` Compose service.
Use `--bootstrap-url <HTTPS_URL>` to explicitly select another descriptor.
The target's running chain ID must match the descriptor. No release, model,
governance proposal, operator inventory or keyring is required.

All DevShard processes managed by this supervisor may briefly stop. The command
does not change approved versions, upgrade `inferenced`, DAPI, the router or ML
services, or send governance transactions. It does not test inference readiness.

The SSH account needs passwordless sudo; the Host needs Bash, jq, GNU coreutils,
Docker and Docker Compose supporting `config --no-env-resolution`. Older Compose
versions are refused before changing the deployment. Only `/srv/dai/deploy`
is supported, discovered from the running container's Compose labels.
Legacy `/srv/dai/node`, nested `/srv/dai/deploy/<host>` and all other paths
are refused before any deployment changes; this command does not migrate them.
Multiple running `versiond` services are refused as ambiguous.

The command retains a private receipt under the deployment's
`.gdc-versiond-upgrades/` directory, including the previous Compose layer. It
checks that the effective configuration changes only `versiond.image`, keeps
data mounts intact and verifies that the selected image stays running. An
already matching stable service is not restarted. Failed activation attempts
restore the previous local image and Compose file; a failed recovery is reported
with its receipt path and requires inspection before retrying.

## Core 0.2.14 to 0.2.15 governance upgrade

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
