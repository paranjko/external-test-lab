# Network bootstrap software contract

`bootstrap.json` identifies a network through its chain ID, Genesis digest and
seed endpoints. The optional `software` object declares the software to install
for a **new node on that network**. It is reviewed data, not a report of what
individual servers happen to run.

Both repository validators accept old documents without `software`. When the
field is present, the complete software v1 object is required; `null`, an empty
object, unknown fields and unsupported versions are errors.

## Software v1

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1`; version of this software contract |
| `platform` | One explicit target, `linux/amd64` or `linux/arm64` |
| `accelerator` | Required execution stack: `cuda`, `rocm` or `cpu` |
| `deployment` | HTTPS source repository, full Git commit and ordered Compose file paths with SHA-256 digests |
| `components` | Component-role map of exact image references and expected running versions; requires `node`, `api`, `tmkms`, `mlnode` |
| `operator_cli` | Expected inferenced version and a checksummed executable archive for the declared platform |
| `model` | Model repository ID, full revision, context length, concurrency, GPU memory fraction, dtype and tensor parallel size |

Every image includes `@sha256:<64 lowercase hexadecimal characters>`; a tag
alone is insufficient. Tags are descriptive, digests select the bytes.
Every archive specifies an HTTPS URL, SHA-256, `format: "zip"` and the relative
path of its executable. Source paths and executable paths cannot escape their
respective roots.

`components.node.version` and `components.api.version` describe the expected
**running binary**, not the container tag. Their optional `commit` records the
full source commit reported by that executable; GDC requires it for runtime
readback. Either entry may contain
`upgrade: {name, artifact}` to specify a Cosmovisor binary override. For
example, the upgrade name can be `v0.2.16` while the running binary version is
`v0.2.16-post1`. Without `upgrade`, the executable bundled in the pinned image
must provide the declared version. The operator CLI version must equal the
node runtime version; its archive can differ from the container runtime archive.

The Compose files, applied in their listed order, define service wiring,
commands and default configuration. Component keys identify roles in that
recipe, not necessarily literal Compose service names. Include every enabled
service, including supporting services such as
`postgres`, `versiond`, proxies and exporters. Disabled services are not
started. For example, GDC maps `mlnode` to the local or remote GPU service,
`inference-proxy` to its `inference` service, and `proxy-policy` to both policy
workers. A bridge image is available for the separately enabled bridge role;
declaring its image does not enable that role. An installer may translate the
recipe into its own deployment layout,
but must preserve the declared service relationships and software identities.
It must reject missing image pins for enabled services and unknown required
services rather than invent defaults.

The model fields override the recipe's model defaults. Host addresses, SSH
credentials, signing keys, storage paths and local/remote GPU placement remain
operator inputs. This is a software selection contract, not a generic remote
execution format or a promise that every target GPU supports the image.
There is one explicit target per document in v1: no automatic choice between
hardware variants and no fallback to another image.

DevShard binaries remain governed by the chain's approved-version list and
versiond reconciliation. Pinning the versiond image does not replace that
on-chain authority. Likewise, software does not override Genesis, PoC parameters,
membership rules, upgrade schedules or signer-safety checks.

## Consumer rules

1. Validate the complete bootstrap and bind it to its chain ID and Genesis hash.
2. Check that the installer understands software v1, its platform, accelerator,
   recipe and components. If software is present but unsupported, stop before
   changing the host; do not fall back to network version polling.
3. Resolve the pinned source commit and verify the listed Compose file hashes.
   A built-in adapter may recognize an already verified recipe by its hashes.
   Resolve images by digest and verify archives before extraction. Reject
   archive traversal and links escaping the destination; retain accompanying
   runtime libraries, not just the executable.
4. Build the installation plan from the declared components and model settings.
   For a scheduled Cosmovisor upgrade, place the executable and libraries under
   `cosmovisor/upgrades/<name>/bin`. A fresh state-sync JOIN instead uses the
   declared current runtime as `cosmovisor/genesis/bin`, including its libraries.
   This initializes a new service home, not the chain's Genesis version. Selecting
   the startup binary must respect the chain's current upgrade state; copying
   files alone does not activate a binary. Never use skip-upgrade flags to force
   acceptance of an incompatible runtime.
5. Record the original bootstrap bytes and their SHA-256 with the plan. A
   changed descriptor requires a newly reviewed plan, not an in-place switch.
6. Verify running versions, synchronization and the normal JOIN acceptance
   conditions. Schema validity is not proof of artifact availability,
   compatibility or validator admission.

Bootstrap JSON is never sourced as shell code. When software is absent, a
consumer may retain its explicitly documented legacy selection method.
`bootstrap.env` remains the existing network-endpoint projection; it deliberately
does not flatten software into shell variables.

## Validation and reading

```bash
make -C net-deployment-runbook test-network-bootstrap
bash net-deployment-runbook/scripts/network-bootstrap.sh verify bootstrap.json
bash net-deployment-runbook/scripts/network-bootstrap.sh software bootstrap.json
```

The last command returns only the validated software object as JSON. It fails
with no stdout when software is absent or invalid. The Python validator exposes
the same `software FILE` command. Neither command downloads or installs software.

[software-v1.json](examples/software-v1.json) is a synthetic conformance example:
the domains, commits and checksums are placeholders, **not a deployable release**.
Its version labels demonstrate that image and runtime versions can differ; they
do not select the next DevNet release.

## PR-based publication

Changes to a network's software set belong in a PR editing its document under
`bootstrap/release/`. Review the entire set, artifact provenance, model revision
and compatibility together. Do not derive it from whichever node answers first.
Use a separate PR for each approved composition change and retain its predecessor
in Git. Verify availability and rehearse the selected composition on the stand
before publishing it for JOIN.

The schema is self-contained. Keep `v1.bootstrap.schema.json` and
`release/v1.bootstrap.schema.json` byte-identical so the existing schema
attestation and delivery process can publish it without external schema files.

Roll out readers **before** publishing documents containing software: old strict
v1 readers reject unknown top-level fields. GDC JOIN uses the declaration when
present and retains the network-observation path only when it is absent.
This does not implement a `gonkactl` installer. Do not publish the example.

## Current GDC adapter and DevNet declaration

The DevNet descriptor pins `v2026.10.06.lock` with the explicit community-lab,
qwen3-0.6b and gdc-lab support layers. Its Core/DAPI runtime is `0.2.16-post1`;
MLNode is `3.0.16`. Container envelopes and operator CLI archives remain separate
from runtime overrides

The adapter supports the declared Qwen3-0.6B CUDA `linux/amd64` recipe and checks
its two Compose hashes before any provisioning. Other recipes, platforms,
accelerators or unknown component roles stop without falling back to polling
or replacing pinned images. Portable-image overrides are not accepted for this
declaration

The installer stages verified Core/DAPI bundles, including their libraries,
then creates the single-Host proxy-router, two policy workers and versiond-router
topology. DevShard routing follows the DAPI catalog; approved DevShard versions
remain on-chain. On restart, the initial bundle is checked but a later
Cosmovisor `current` selection is preserved

`--preflight` (and its compatibility spelling `--plan`) compiles this local
profile without downloading runtime archives or changing a Host. It does not
prove state-sync, GPU qualification, registration or validator admission. The
ordinary JOIN retains the chain-trust, clean-Host, signerless synchronization
and runtime-readback gates
