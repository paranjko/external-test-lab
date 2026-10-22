#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo "Usage: $0 SSH_ALIAS APPROVED_RAW_GENESIS_SHA256 GENESIS_SOFTWARE_FRAGMENT" >&2; }
[[ $# == 3 ]] || { usage; exit 2; }
NODE="$1"; EXPECTED_GENESIS_SHA256="$2"; SOFTWARE_FILE="$3"
[[ "$NODE" =~ ^[a-z0-9][a-z0-9_-]*$ && "$EXPECTED_GENESIS_SHA256" =~ ^[0-9a-f]{64}$ \
  && -f "$SOFTWARE_FILE" && ! -L "$SOFTWARE_FILE" ]] || { usage; exit 2; }
jq -e '
  .schema_version == 1 and .kind == "gdc-genesis-software-fragment"
  and .source.release_profile == "v2026.10.06"
  and (.spec.deployment.software.components.node.commit | test("^[0-9a-f]{40}$"))
  and (.spec.deployment.software.components.api.commit | test("^[0-9a-f]{40}$"))
  and (.binary_sha256.inferenced | test("^[0-9a-f]{64}$"))
  and (.binary_sha256.decentralized_api | test("^[0-9a-f]{64}$"))
' "$SOFTWARE_FILE" >/dev/null || { echo 'approved Genesis software fragment is malformed' >&2; exit 1; }
fragment_sha="$(sha256sum "$SOFTWARE_FILE" | awk '{print $1}')"
base_compose_sha="$(sha256sum "$ROOT/02-node/compose.yaml" | awk '{print $1}')"
bootstrap_jq_b64="$(base64 <"$ROOT/02-node/bootstrap-compose.jq" | tr -d '\n')"
ssh -T "$NODE" sudo bash -s -- /srv/dai "$EXPECTED_GENESIS_SHA256" "$fragment_sha" \
  "$NODE" /srv/dai-archives "$base_compose_sha" "$bootstrap_jq_b64" \
  <"$ROOT/scripts/repair-genesis-startup-remote.sh"
