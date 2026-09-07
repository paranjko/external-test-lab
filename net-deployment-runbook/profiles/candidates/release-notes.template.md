# External Test Lab candidate {{PROFILE}}

Independent laboratory build for {{LAYER}} evaluation. This is not an official Gonka release or readiness statement.

## Build scope

- Candidate profile: `{{PROFILE}}`
- Layer: `{{LAYER}}`
- Stable core baseline: `{{CORE_PROFILE}}` – Gonka `{{GONKA_RELEASE}}`
- Source repository: `{{SOURCE_REPOSITORY}}`
- Source ref: `{{SOURCE_REF}}`
- Source commit: `{{SOURCE_COMMIT}}`
- Target platform: `linux/amd64`
- Protocol version: `{{PROTOCOL_VERSION}}`

The candidate includes only the components declared in its immutable candidate definition. Components outside that definition are unchanged.

## Docker and upgrade artifacts

| Artifact | Purpose | SHA-256 / OCI digest |
| --- | --- | --- |
| `{{RUNTIME_OCI_ARCHIVE}}` | DevShard runtime OCI archive | `{{RUNTIME_ARCHIVE_SHA256}}` / `{{RUNTIME_OCI_DIGEST}}` |
| `{{HOST_OCI_ARCHIVE}}` | DevShard Host OCI archive | `{{HOST_ARCHIVE_SHA256}}` / `{{HOST_OCI_DIGEST}}` |
| `{{GATEWAY_OCI_ARCHIVE}}` | DevShard Gateway OCI archive | `{{GATEWAY_ARCHIVE_SHA256}}` / `{{GATEWAY_OCI_DIGEST}}` |
| `{{UPGRADE_ARCHIVE}}` | Upgrade binary archive | `{{UPGRADE_ARCHIVE_SHA256}}` |

Each artifact has a SHA-256 sidecar and an SPDX SBOM. The candidate build manifest is the authoritative binding for source, components, image digests, binary checksums, and build workflow provenance.

## Manual reproduction

Use an External Test Lab checkout containing the candidate definition, Docker/Buildx, authenticated GitHub CLI, and permission to publish a laboratory candidate:

```bash
git clone https://github.com/paranjko/external-test-lab.git
cd external-test-lab/net-deployment-runbook

./gdc.sh release candidate prepare \
  --source-ref {{SOURCE_REF}} \
  --layer {{LAYER}} \
  --profile {{PROFILE}}
./gdc.sh release candidate build {{PROFILE}} --wait
./gdc.sh release candidate verify {{PROFILE}}
```

`prepare` freezes the candidate definition. `build` uses reviewed default-branch automation to build, sign, and publish the artifacts. `verify` reconstructs and checks the immutable profile from its definition and build manifest.

## Verify downloaded artifacts

For every downloaded artifact, first check its release checksum and then its GitHub provenance certificate:

```bash
artifact={{UPGRADE_ARCHIVE}}
curl -fLO "https://github.com/paranjko/external-test-lab/releases/download/{{PROFILE}}/$artifact"
curl -fLO "https://github.com/paranjko/external-test-lab/releases/download/{{PROFILE}}/$artifact.sha256"
sha256sum --check "$artifact.sha256"
gh attestation verify "$artifact" -R paranjko/external-test-lab
```

The last command verifies the artifact digest and its signed GitHub build provenance. No workflow-path policy is required.

To verify that the signed SPDX SBOM is bound to the same artifact, use the same command with the SPDX predicate type:

```bash
gh attestation verify "$artifact" \
  -R paranjko/external-test-lab \
  --predicate-type https://spdx.dev/Document
```

Repeat this procedure for each OCI archive. Do not treat an SPDX file for one artifact as evidence for a different ZIP or OCI archive.
