#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$ROOT/.data/preview-runtime-config-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
revision=0123456789012345678901234567890123456789

mkdir -p "$tmp/release"
printf '<script src="config.js"></script>\n' >"$tmp/release/index.html"
cat >"$tmp/rendered.js" <<'JS'
window.GDC_CONFIG = {"chainId":"gonka-devnet-community","model":"Qwen","gatewayNode":"node4","chainRpcHost":"node4.gonka-dev.net","nodes":[{"name":"node4","publicHost":"node4.gonka-dev.net"}],"nodeCatalog":[{"name":"node4","publicHost":"node4.gonka-dev.net","statusBase":"/status/node4"}]};
JS
cat >"$tmp/inventory.json" <<'JSON'
{"node_catalog":[{"name":"node4","publicHost":"node4.gonka-dev.net","geo":{"latitude":45.5234482,"longitude":-122.6762071}}]}
JSON

"$ROOT/scripts/prepare-isolated-preview-runtime-config.sh" "$tmp/release" "$tmp/rendered.js" 172 "$revision" "$tmp/inventory.json"
grep -Fq 'src="config.js"' "$tmp/release/index.html"
! grep -Fq 'src="/config.js"' "$tmp/release/index.html"
grep -Fq 'src="preview-status-adapter.js"' "$tmp/release/index.html"
grep -Fq 'input.startsWith("/status/")' "$tmp/release/preview-status-adapter.js"
jq -e '
  .gatewayNode == "node4" and
  .statusBase == "/172/status" and
  .chainRpcOrigin == "/172/status/node4" and
  .nodeCatalog[0].statusBase == "/172/status/node4" and
  .nodeCatalog[0].geo.latitude == 45.5234482
' < <(sed -n 's/^window\.GDC_CONFIG = //; s/;$//; p' "$tmp/release/config.js") >/dev/null
jq -e --arg revision "$revision" '
  .schema_version == 1 and .source_revision == $revision and .preview_number == 172 and
  (.renderer_config_sha256 | test("^[0-9a-f]{64}$")) and
  (.config_sha256 | test("^[0-9a-f]{64}$")) and
  (.status_adapter_sha256 | test("^[0-9a-f]{64}$")) and
  (.inventory_receipt_sha256 | test("^[0-9a-f]{64}$"))
' "$tmp/release/preview-runtime-config.json" >/dev/null

printf 'PASS isolated preview runtime config is generation-bound and relative\n'
