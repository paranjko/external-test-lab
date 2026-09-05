#!/usr/bin/env bash
# Ensure the running canary consumed the receipt rather than recomputing trust
# from SEED_NODE_RPC_URL inside the upstream image helper.
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DEPLOY_DIR RECEIPT" >&2; exit 2; }
deploy="$1"; receipt="$2"
[[ -d "$deploy" && -r "$receipt" ]] || { echo 'invalid state-sync config verification input' >&2; exit 2; }
trust_height="$(jq -er '.bootstrap.trust.height | tonumber' "$receipt")"
trust_hash="$(jq -er '.bootstrap.trust.block_id' "$receipt")"
# The upstream init helper canonicalizes Comet RPC paths with a trailing slash.
# Receipts intentionally retain network URLs without that presentation detail,
# so normalize both receipt records to the value written into config.toml.
rpc_1="$(jq -er '.fault_domains[0].rpc_url | rtrimstr("/") + "/"' "$receipt")"
rpc_2="$(jq -er '.fault_domains[1].rpc_url | rtrimstr("/") + "/"' "$receipt")"
peers="$(jq -er '[.bootstrap.snapshot.providers[] | sub("@tcp://"; "@")] | join(",")' "$receipt")"
config_matches_receipt() {
  grep -Eq '^enable = true$' <<<"$config" &&
    grep -Fq "rpc_servers = \"$rpc_1,$rpc_2\"" <<<"$config" &&
    grep -Fq "trust_height = $trust_height" <<<"$config" &&
    grep -Fq "trust_hash = \"$trust_hash\"" <<<"$config" &&
    grep -Fq "persistent_peers = \"$peers\"" <<<"$config"
}
config=''
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  config="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" exec -T node sh -c 'cat /root/.inference/config/config.toml' 2>/dev/null || true)"
  config_matches_receipt && break
  sleep 2
done
grep -Eq '^enable = true$' <<<"$config" || { echo 'lineage_verification_failed: statesync is not enabled in canary config' >&2; exit 1; }
grep -Fq "rpc_servers = \"$rpc_1,$rpc_2\"" <<<"$config" || { echo 'lineage_verification_failed: canary RPC servers differ from receipt' >&2; exit 1; }
grep -Fq "trust_height = $trust_height" <<<"$config" || { echo 'lineage_verification_failed: canary trust height differs from receipt' >&2; exit 1; }
grep -Fq "trust_hash = \"$trust_hash\"" <<<"$config" || { echo 'lineage_verification_failed: canary trust hash differs from receipt' >&2; exit 1; }
grep -Fq "persistent_peers = \"$peers\"" <<<"$config" || { echo 'lineage_verification_failed: canary P2P providers differ from receipt' >&2; exit 1; }
printf 'PASS signerless canary config matches receipt trust and P2P providers\n'
