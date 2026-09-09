External Test Lab {{LAYER}} evaluation build. This is not an official Gonka release or readiness statement.

## Build scope

- Candidate profile: `{{PROFILE}}`
- Layer: `{{LAYER}}`
- Stable core baseline: {{CORE_BASELINE}}
- Candidate definition SHA-256: `{{DEFINITION_SHA256}}`
- Target platform: `linux/amd64`

{{SOURCE_LINES}}

The candidate includes only the components declared in its immutable candidate definition. Components outside that definition are unchanged.

## Docker and upgrade artifacts

| Artifact | Purpose | SHA-256 / OCI digest |
| --- | --- | --- |
{{ARTIFACT_ROWS}}

Each artifact has a SHA-256 sidecar and an SPDX SBOM. The candidate build manifest is the authoritative binding for source, components, image digests, binary checksums, and build workflow provenance.

## Manual reproduction

Use an External Test Lab checkout containing the candidate definition, Docker/Buildx, authenticated GitHub CLI, and permission to publish a laboratory candidate:

```bash
git clone https://github.com/paranjko/external-test-lab.git
cd external-test-lab/net-deployment-runbook

./gdc.sh release candidate prepare \
  --source-ref <frozen-source-ref> \
  --layer {{LAYER}} \
  --profile {{PROFILE}}
./gdc.sh release candidate build {{PROFILE}} --wait
./gdc.sh release candidate verify {{PROFILE}}
```

`prepare` freezes the candidate definition. `build` uses reviewed default-branch automation to build, sign, and publish the artifacts. `verify` reconstructs and checks the immutable profile from its definition and build manifest.

## Verify downloaded artifacts

For every downloaded artifact, first check its release checksum and then its GitHub provenance certificate:

```bash
artifact={{EXAMPLE_ARTIFACT}}
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
