# Network bootstraps and publication

Each network has two reviewed files in this directory:
`<chain_id>.json` is the descriptor and `<chain_id>.env` is its deterministic
endpoint projection. Standalone JSON Schemas live in [schema/](../schema).
Examples are kept in subdirectories and are never published.

The optional [software contract](SOFTWARE.md) pins the installation inputs.
The DevNet descriptor includes the
[`v2026.10.06` profile](../net-deployment-runbook/profiles/releases/v2026.10.06.lock).
Publication does not install these components or establish validator admission.

## Change a bootstrap

Edit its JSON in a PR, then regenerate the ENV projection:

```bash
python3 net-deployment-runbook/scripts/network-bootstrap.py env \
  bootstrap/gonka-devnet-community.json > bootstrap/gonka-devnet-community.env
make -C net-deployment-runbook test-network-bootstrap test-bootstrap-publication test-bootstrap-monitor
```

Keep the filename equal to `chain_id`. A stale or missing ENV, invalid schema,
duplicate JSON key or unpinned software component prevents publication.
No secret, credential or private key belongs in these files.

## Automatic delivery

Changes to `bootstrap/**` or `schema/**` on `main` run
**Publish schemas and network bootstraps**. Manual dispatch is allowed on
`main` only. The workflow:

1. Validates every schema and every JSON/ENV pair, including newly added files
2. Builds a complete release with a SHA-256 inventory and source revision
3. Creates GitHub artifact attestations for every public file
4. Uploads a new directory over host-key-verified SSH as `ops`
5. Verifies the upload and switches the public directory to the new release
6. Reads every HTTPS URL back and compares its exact bytes

Public paths are:

- `https://gonka-dev.net/<schema-filename>.schema.json`
- `https://gonka-dev.net/<chain_id>/bootstrap.json`
- `https://gonka-dev.net/<chain_id>/bootstrap.env`

The existing `/<chain_id>/bootstrap` alias remains available. Paths do not
require separate TLS certificates: Caddy uses the existing domain certificate.
Artifact attestations provide separate, verifiable provenance for the files.
See [GitHub's attestation action](https://github.com/actions/attest).

```bash
gh attestation verify ./bootstrap.json --repo paranjko/external-test-lab
```

The workflow uses the existing `gonka-dev-site-publish` Environment's
`GONKA_DEV_SITE_DEPLOY_HOST`, `GONKA_DEV_SITE_DEPLOY_USER`,
`GONKA_DEV_SITE_DEPLOY_PRIVATE_KEY`, and `GONKA_DEV_SITE_DEPLOY_KNOWN_HOSTS`
secrets. It does not need root access, Docker or new sudo rules.

Releases live under `/srv/dai/edge/bootstrap/releases/`; `current` selects the
public directory. Switching an existing symlink is atomic. The first delivery
preserves a legacy real directory before creating the symlink; that one-time
migration has a brief two-operation switch. Previous and failed releases remain
available for inspection. A failed public readback restores the previous release
only if this invocation activated the failing generation; it never rolls back
another publisher or an already-active release.

Each failed HTTPS readback logs the artifact path, attempt number and a bounded reason: HTTP status, DNS, TLS, timeout, connection failure, refused redirect or content mismatch

Diagnostics do not print response bodies, redirect targets or raw transport exception messages, retries and exact-byte verification remain unchanged

Seed outages do not block delivery of corrected metadata. The separate
[daily monitor](MONITORING.md) checks publication currency and seed availability,
then notifies Telegram once per failed network.

## One-time edge preparation

An administrator runs this on the public edge with the two repository scripts
available locally:

```bash
sudo bash ops/chore/setup-bootstrap-publisher.sh \
  net-deployment-runbook/scripts/bootstrap-release.py
```

The script validates and gracefully reloads Caddy with a generic
`/*.schema.json` route, keeps the previous Caddyfile, and grants `ops`
ownership of the bootstrap directory and any legacy real `current` directory.
The latter needs write access to move into `releases` during first publication.
Ownership changes are not recursive; an already-managed `current` symlink and
its target are left untouched. It leaves existing artifact files,
SSH keys, sudo policy, site content and node services unchanged. The script
expects the existing `/srv/dai/edge/compose.yaml` layout and the `caddy`
service; it refuses an unrecognized configuration.
Repeated edge installation preserves bootstrap publisher ownership in both
the legacy and per-node deployment layouts.

Prepare and inspect a release without contacting the server:

```bash
make -C net-deployment-runbook prepare-bootstrap-release \
  bootstrap_release_dir=/tmp/bootstrap-release
```

Choose a fresh output directory. The release manifest and public files are
retained as a CI artifact for 30 days on success or failure.
