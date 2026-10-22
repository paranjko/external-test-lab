#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERER="$ROOT/scripts/render-genesis-software.sh"
RELEASE="$ROOT/profiles/releases/v2026.10.06.lock"
MODEL="$ROOT/../model/qwen3-0.6b.lock"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
fixture="$temporary/fixture"
mkdir -p "$temporary/bin" "$fixture/net-deployment-runbook/scripts" \
  "$fixture/net-deployment-runbook/profiles/releases" \
  "$fixture/net-deployment-runbook/profiles/deployments" \
  "$fixture/net-deployment-runbook/profiles/operator-services" \
  "$fixture/model"

# Fail immediately if the renderer ever reaches out to hosts or networks.
for command_name in ssh curl; do
  printf '#!/bin/sh\nprintf "unexpected %s invocation\\n" >&2\nexit 99\n' "$command_name" \
    >"$temporary/bin/$command_name"
  chmod 0755 "$temporary/bin/$command_name"
done
clean_path="$temporary/bin:/usr/bin:/bin"

env -i PATH="$clean_path" bash "$RENDERER" qwen3-0.6b "$temporary/package.json"
jq -e '
  .schema_version == 1 and .kind == "gdc-genesis-software-fragment"
  and .source.release_profile == "v2026.10.06"
  and .spec.deployment.software.components.node.upgrade.artifact.sha256 == "d2ef13374fb15518a02ae5fac83d139d66fb79a8c93d97f4e78b43ce30e14f98"
  and .spec.deployment.software.components.api.upgrade.artifact.sha256 == "f64b9433cd27d9ee433f1aede89d6be910f6deb8df644d55e2dfe30b8f873802"
  and .binary_sha256.inferenced == "2f6a31c3ecda063a84fcfd80782fe5b00908f9b678da9204d6c7acba602260de"
  and .binary_sha256.decentralized_api == "332699b4ec760569f5670c6e1feb9d579c2a0c4ec6e0cc5095bf74ea1a37007f"
  and .spec.deployment.software.components.node.image == "ghcr.io/product-science/inferenced:0.2.15@sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112"
  and .spec.deployment.software.components.api.image == "ghcr.io/product-science/api:0.2.15-post3@sha256:3f81b7a9dfac66690e4a934a916662b248f20838dd8f7b47f1863fd3c5c5cd9c"
' "$temporary/package.json" >/dev/null
jq -e '{software:.spec.deployment.software}' "$temporary/package.json" \
  | jq -e -f "$ROOT/scripts/bootstrap-software.jq" >/dev/null

cp "$RENDERER" "$fixture/net-deployment-runbook/scripts/render-genesis-software.sh"
cp "$ROOT/scripts/bootstrap-software.jq" "$fixture/net-deployment-runbook/scripts/bootstrap-software.jq"
cp "$RELEASE" "$fixture/net-deployment-runbook/profiles/releases/v2026.10.06.lock"
cp "$ROOT/profiles/deployments/community-lab.lock" "$fixture/net-deployment-runbook/profiles/deployments/"
cp "$ROOT/profiles/operator-services/gdc-lab.lock" "$fixture/net-deployment-runbook/profiles/operator-services/"
cp "$MODEL" "$fixture/model/qwen3-0.6b.lock"

sed -i 's/^INFERENCED_BINARY_SHA256=.*/INFERENCED_BINARY_SHA256=not-a-digest/' \
  "$fixture/net-deployment-runbook/profiles/releases/v2026.10.06.lock"
if env -i PATH="$clean_path" bash "$fixture/net-deployment-runbook/scripts/render-genesis-software.sh" \
  qwen3-0.6b "$temporary/bad-release.json" \
  >"$temporary/bad-release.stdout" 2>"$temporary/bad-release.stderr"; then
  echo 'invalid release digest unexpectedly accepted' >&2
  exit 1
fi
grep -Fq 'INFERENCED_BINARY_SHA256 is missing a valid SHA-256' "$temporary/bad-release.stderr"

cp "$RELEASE" "$fixture/net-deployment-runbook/profiles/releases/v2026.10.06.lock"
printf '\nGDC_MODEL_PROFILE_SCOPE=qualification-only\n' >>"$fixture/model/qwen3-0.6b.lock"
if env -i PATH="$clean_path" bash "$fixture/net-deployment-runbook/scripts/render-genesis-software.sh" \
  qwen3-0.6b "$temporary/bad-model.json" \
  >"$temporary/bad-model.stdout" 2>"$temporary/bad-model.stderr"; then
  echo 'qualification-only model unexpectedly accepted' >&2
  exit 1
fi
grep -Fq 'qualification-only model profiles cannot be used for Genesis' "$temporary/bad-model.stderr"

echo 'PASS Genesis software pins, Bootstrap software contract, and refusal cases'
