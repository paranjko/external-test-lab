#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile=v2026.08.28-rc.0
definition="$ROOT/profiles/candidates/$profile.definition.json"
sidecar="$ROOT/profiles/candidates/$profile.definition.sha256"

(
  cd "$(dirname "$definition")"
  sha256sum --check --strict "$(basename "$sidecar")"
)

jq -e --arg profile "$profile" '
  .schema_version == 1
  and .kind == "external-test-lab-candidate-definition"
  and .profile == $profile
  and .layer == "core"
  and .classification == "lab-candidate"
  and .official_gonka_release == false
  and .source_identity_contract == "git-object-and-github-signature-v1"
  and .upgrade_from_profile == "v2026.08.06"
  and .repositories.gonka_core.ref == "refs/heads/ak/height-sync-protocol-dapi"
  and .repositories.gonka_core.commit == "18506d42c510e0cafe6acd748bcd8d83036cba40"
  and .repositories.gonka_core.tree == "1e2b267b21868096736b9aece8bb3bdbaf666406"
  and .upstream_qualification.pull_request == "https://github.com/gonka-ai/gonka/pull/1622"
  and .upstream_qualification.base_ref == "refs/heads/upgrade-v0.2.16"
  and .publication.release_tag == $profile
  and .devshard_baseline.profile == "v2026.08.30-rc.0"
  and .devshard_baseline.definition_sha256 == "956a7758af5ba16cb47e7c09e8f18a8b3646ee1486d86749e3cf1db5c1820d86"
  and .devshard_baseline.build_manifest_sha256 == "0ca70f36cee0a38e44b16d163fc5c1e181e771e01bfec285d7ecd4417eace083"
  and .repositories.gonka_core.signature.provider == "github"
  and .repositories.gonka_core.signature.verified == true
  and (.repositories.gonka_core.signature.signature_sha256 | test("^[0-9a-f]{64}$"))
  and (.repositories.gonka_core.signature.payload_sha256 | test("^[0-9a-f]{64}$"))
  and .features.dapi_block_oracle.enabled == true
  and .features.height_sync.hash_aware_retest_required == true
  and ([.components[] | select(.action == "build-candidate") | .source] | unique) == ["gonka_core"]
  and ([.component_boundary.excludes[]] | sort) == ["devshard-gateway", "devshard-host", "devshardd"]
' "$definition" >/dev/null

prepare="$(
  "$ROOT/gdc.sh" release candidate prepare \
    --source-ref ak/height-sync-protocol-dapi --layer core
)"
grep -Fq "READY profile=$profile layer=core" <<<"$prepare"

matrix="$(python3 "$ROOT/scripts/release-candidate.py" workflow-matrix "$profile")"
grep -Fxq 'layer=core' <<<"$matrix"
grep -Fxq "release_tag=$profile" <<<"$matrix"
grep -Fq '"id": "decentralized-api", "source": "core"' <<<"$matrix"
grep -Fq 'DEVSHARD_VERSION=v5' <<<"$matrix"
grep -Fq 'Version=0.2.16' <<<"$matrix"
grep -Fq 'Commit=18506d42c510e0cafe6acd748bcd8d83036cba40' <<<"$matrix"
if grep -Fq 'INFERENCED_LDFLAGS' <<<"$matrix"; then
  echo 'core candidate must build the unmodified upstream DAPI Dockerfile' >&2
  exit 1
fi
grep -Fq '"legacy_dapi_metadata": false' <<<"$matrix"

legacy_matrix="$(python3 "$ROOT/scripts/release-candidate.py" workflow-matrix v2026.08.25-rc.0)"
grep -Fq '"legacy_dapi_metadata": true' <<<"$legacy_matrix"
grep -Fq 'INFERENCED_LDFLAGS=' <<<"$legacy_matrix"
if grep -Fq '"source": "v5"' <<<"$matrix"; then
  echo 'core candidate must not rebuild DevShard artifacts' >&2
  exit 1
fi

printf 'PASS v0.2.16 hash-aware DAPI candidate boundary\n'
