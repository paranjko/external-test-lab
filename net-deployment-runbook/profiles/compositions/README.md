# Deployed-State Composition Manifests

Files in this directory freeze explicit compositions of independent Gonka core
and DevShard profiles for External Test Lab deployments.

Each `*.json` composition manifest binds:
- One Gonka core profile (stable release lock or lab candidate definition)
- One DevShard profile (stable release lock or lab candidate definition)
- Canonical network lineage (`chain_id` and `genesis_sha256`)
- Non-overlapping composite component and artifact matrix
- Feature flags, runtime parameters, and lock checksums

Its adjacent `*.sha256` file binds the exact manifest bytes.

## Lifecycle Commands

Create a composition manifest from reviewed profiles:

```bash
./gdc.sh release composition create \
  --core v2026.08.06 \
  --devshard v2026.08.06 \
  [--output profiles/compositions/core-v2026.08.06+devshard-v4.json]
```

Verify a composition manifest against immutable profile locks:

```bash
./gdc.sh release composition verify \
  profiles/compositions/core-v2026.08.06+devshard-v4.json
```

Verification guarantees that:
1. The composition manifest matches its cryptographic SHA-256 sidecar.
2. The core profile lock exists, is uncorrupted, and matches its recorded `lock_hash`.
3. The DevShard profile lock exists, is uncorrupted, and matches its recorded `lock_hash`.
4. Core and DevShard component sets do not overlap and cover all required node roles.
5. Target network lineage matches the canonical DevNet (`gonka-devnet-community` and Genesis hash).
