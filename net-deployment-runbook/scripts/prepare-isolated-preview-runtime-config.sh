#!/usr/bin/env bash
set -Eeuo pipefail

# Materialize public runtime configuration inside an immutable preview
# generation. It comes from the source-bound renderer output, not production.

release_dir="${1:-}"
renderer_config="${2:-}"
preview_number="${3:-}"
revision="${4:-}"
inventory_receipt="${5:-}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }

[[ -d "$release_dir" && ! -L "$release_dir" ]] || die 'release directory is unavailable or unsafe'
[[ -f "$renderer_config" && ! -L "$renderer_config" ]] || die 'renderer configuration is unavailable or unsafe'
[[ "$preview_number" =~ ^[1-9][0-9]*$ ]] || die 'preview number must be positive'
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview revision must be a full SHA-1'
[[ -z "$inventory_receipt" || ( -f "$inventory_receipt" && ! -L "$inventory_receipt" ) ]] || die 'inventory receipt is unsafe'

input_sha256="$(sha256sum "$renderer_config" | awk '{print $1}')"
input_json="$(sed -n 's/^window\.GDC_CONFIG = //; s/;$//; p' "$renderer_config")"
[[ -n "$input_json" ]] || die 'renderer configuration does not contain window.GDC_CONFIG'

inventory_catalog='[]'
inventory_receipt_sha256=''
if [[ -n "$inventory_receipt" ]]; then
  inventory_receipt_sha256="$(sha256sum "$inventory_receipt" | awk '{print $1}')"
  inventory_catalog="$(jq -ce '
    .node_catalog as $catalog |
    if (
      ($catalog | type == "array" and length > 0 and
        all(.[]?;
          (.name | type == "string" and test("^node[0-9]+$")) and
          (.publicHost | type == "string" and test("^node[0-9]+\\.gonka-dev\\.net$")) and
          ((.geo == null) or ((.geo.latitude | type == "number") and (.geo.longitude | type == "number")))
        )
      )
    ) then $catalog else error("unsafe inventory catalog") end
  ' "$inventory_receipt")" || die 'inventory receipt has an unsafe node catalog'
fi

config_json="$(jq -ce --arg prefix "/$preview_number/status" --argjson inventory "$inventory_catalog" '
  if (
    (.chainId | (type == "string") and (length > 0)) and
    (.model | (type == "string" or type == "number")) and
    (.gatewayNode | (type == "string") and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.chainRpcHost | (type == "string") and test("^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$")) and
    (.nodes | type == "array") and
    (.nodeCatalog | (type == "array") and (length > 0)) and
    (all(.nodeCatalog[];
      (.name | (type == "string") and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
      (.publicHost | (type == "string") and test("^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$"))
    )) and
    (([.nodeCatalog[].name] | length) == ([.nodeCatalog[].name] | unique | length)) and
    (([.nodeCatalog[].publicHost] | length) == ([.nodeCatalog[].publicHost] | unique | length)) and
    (.chainRpcHost as $chain_host | [.nodeCatalog[].publicHost] | index($chain_host) != null) and
    (($inventory | length) == 0 or (([.nodeCatalog[].name] | sort) == ([$inventory[].name] | sort)))
  ) then
    .statusBase = $prefix |
    .nodeCatalog |= map(
      if ($inventory | length) > 0 then
        . as $node |
        ($inventory[] | select(.name == $node.name and .publicHost == $node.publicHost)) as $inventory_node |
        .geo = $inventory_node.geo
      else . end |
      .statusBase = ($prefix + "/" + .name)
    ) |
    .chainRpcHost as $chain_host |
    (.nodeCatalog[] | select(.publicHost == $chain_host) | .name) as $chain_rpc_node |
    .chainRpcOrigin = ($prefix + "/" + $chain_rpc_node) |
    .nodes |= map(if (.name? | type) == "string" then .statusBase = ($prefix + "/" + .name) else . end)
  else error("unsafe preview configuration") end
' <<<"$input_json")" || die 'renderer configuration is not a safe public preview configuration'

index="$release_dir/index.html"
[[ -f "$index" && ! -L "$index" ]] || die 'preview index is unavailable or unsafe'
count="$(grep -Fc 'src="/config.js"' "$index" || true)"
[[ "$count" == 1 ]] || die 'preview index must contain exactly one root config script reference'
sed 's#src="/config\.js"#src="config.js"#' "$index" >"$index.new"
mv -f "$index.new" "$index"

printf 'window.GDC_CONFIG = %s;\n' "$config_json" >"$release_dir/config.js"
output_sha256="$(sha256sum "$release_dir/config.js" | awk '{print $1}')"
adapter="$release_dir/preview-status-adapter.js"
cat >"$adapter" <<'JS'
(() => {
  const base = window.GDC_CONFIG && window.GDC_CONFIG.statusBase;
  if (typeof base !== "string" || !/^\/[1-9][0-9]*\/status$/.test(base)) return;
  const nativeFetch = window.fetch.bind(window);
  window.fetch = (input, init) => {
    if (typeof input === "string" && input.startsWith("/status/"))
      return nativeFetch(`${base}${input.slice("/status".length)}`, init);
    if (input instanceof URL && input.origin === window.location.origin && input.pathname.startsWith("/status/")) {
      const redirected = new URL(input.toString());
      redirected.pathname = `${base}${input.pathname.slice("/status".length)}`;
      return nativeFetch(redirected, init);
    }
    return nativeFetch(input, init);
  };
})();
JS
adapter_sha256="$(sha256sum "$adapter" | awk '{print $1}')"

grep -Fq 'src="config.js"' "$index" || die 'preview index does not load the generation-bound config'
sed 's#<script src="config.js"></script>#<script src="config.js"></script>\n  <script src="preview-status-adapter.js"></script>#' "$index" >"$index.new"
mv -f "$index.new" "$index"
jq -n \
  --arg revision "$revision" \
  --argjson preview "$preview_number" \
  --arg input "$input_sha256" \
  --arg output "$output_sha256" \
  --arg adapter "$adapter_sha256" \
  --arg inventory_receipt "$inventory_receipt_sha256" \
  '{schema_version:1,source_revision:$revision,preview_number:$preview,renderer_config_sha256:$input,config_sha256:$output,status_adapter_sha256:$adapter} + (if $inventory_receipt == "" then {} else {inventory_receipt_sha256:$inventory_receipt} end)' \
  >"$release_dir/preview-runtime-config.json"

printf 'PASS prepared source-bound preview runtime configuration pr=%s revision=%s\n' "$preview_number" "$revision"
