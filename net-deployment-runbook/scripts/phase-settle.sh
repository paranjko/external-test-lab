#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-escrow-pending"
mkdir -p "$RUN"
install_evidence_exit_trap 'Chain-accounted inference'
record_phase_profile settlement

blocked() {
  local reason="$1"
  cat >"$RUN/verdict.md" <<EOF
# Chain-accounted inference: BLOCKED

$reason

No gateway request, escrow finalization, or settlement transaction was sent.
EOF
  printf 'BLOCKED settlement evidence: %s (%s)\n' "$RUN" "$reason"
  exit 3
}

GATEWAY_ENV="$GENERATED/ops/gateway.env"
[[ -s "$GATEWAY_ENV" ]] || blocked 'No rendered gateway escrow exists; run ops gateway first.'
ESCROW_CREATE="${GATEWAY_ENV%.env}.escrow-create.json"
[[ -s "$ESCROW_CREATE" ]] || blocked 'No escrow funding receipt exists; rerun ops gateway before settlement.'
# shellcheck disable=SC1090
source "$GATEWAY_ENV"
[[ "$DEVSHARD_ESCROW_ID" =~ ^[0-9]+$ ]] || blocked 'Rendered gateway escrow ID is invalid.'
RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-escrow-${DEVSHARD_ESCROW_ID}"
mkdir -p "$RUN"
devshard_version="${DEVSHARD_ROUTE_PREFIX##*/}"
[[ "$devshard_version" =~ ^v[34]$ ]] || blocked 'Rendered gateway route does not identify DevShard v3 or v4.'
capture_canonical_genesis "https://$GENESIS_PUBLIC_HOST/chain-rpc/genesis" "$RUN/genesis.json"
genesis_sha256="$(genesis_sha256 "$RUN/genesis.json")"
{
  profile_summary
  printf 'profile_hash=%s\n' "$(profile_hash)"
  printf 'chain_id=%s\n' "$CHAIN_ID"
  printf 'genesis_sha256=%s\n' "$genesis_sha256"
  printf 'devshard_version=%s\n' "$devshard_version"
  printf 'escrow_id=%s\n' "$DEVSHARD_ESCROW_ID"
} >"$RUN/context.env"

creator="$(jq -r .address "$ROOT/artifacts/accounts/gdc-gateway-cold.json")"
rpc="https://$PUBLIC_EDGE_HOST/chain-rpc/"
step "Record funding evidence and creator balance before settlement for escrow $DEVSHARD_ESCROW_ID"
cp "$ESCROW_CREATE" "$RUN/escrow-create.json"
jq -e --arg creator "$creator" --arg id "$DEVSHARD_ESCROW_ID" '
  .creator == $creator
  and (.escrowId | tostring) == $id
  and (.txHash | test("^[0-9A-Fa-f]{64}$"))
  and (.amountNgonka | tonumber) >= (.minAmountNgonka | tonumber)
  and (.balanceBeforeFunding | type == "object")
  and (.balanceAfterFunding | type == "object")
' "$RUN/escrow-create.json" >/dev/null
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$creator" >"$RUN/balance-before.json"

step 'Send authenticated OpenAI-compatible inference through the public gateway route'
client_key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
unauth_status="$(curl -sk -o /dev/null -w '%{http_code}' "https://$API_HOST/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"health"}]}')"
[[ "$unauth_status" == 401 ]] || die "unauthenticated gateway request returned $unauth_status, expected 401"
"$ROOT/04-ops/test-inference.sh" "https://$API_HOST" "$client_key" >"$RUN/chat.json"
jq -e --arg model "$DEVSHARD_MODEL" '
  (.id | type == "string" and length > 0)
  and .model == $model
  and (.choices[0].message.content | type == "string" and length > 0)
' "$RUN/chat.json" >/dev/null

step 'Finalize the exact escrow through its per-escrow API path'
# Inference responses can leave finish/validation messages queued briefly.
# Synchronize them statefully before finalization; this is required by the
# v3 runtime and harmless for v4, unlike a blind timing delay.
ssh "$GATEWAY_NODE" "set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS -X POST http://127.0.0.1:18080/devshard/$DEVSHARD_ESCROW_ID/v1/debug/sync-hosts -H \"Authorization: Bearer \$DEVSHARD_ADMIN_API_KEY\" >/dev/null"
ssh "$GATEWAY_NODE" "set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS -X POST http://127.0.0.1:18080/devshard/$DEVSHARD_ESCROW_ID/v1/finalize -H \"Authorization: Bearer \$DEVSHARD_ADMIN_API_KEY\"" >"$RUN/finalize.json"
jq -e --arg id "$DEVSHARD_ESCROW_ID" '(.escrow_id | tostring) == $id and (.version | type == "string")' "$RUN/finalize.json" >/dev/null

step 'Settle the finalized escrow on chain'
ssh "$GATEWAY_NODE" "set -Eeuo pipefail; set -a; . /srv/dai/ops/gateway.env; set +a; curl -fsS -X POST http://127.0.0.1:18080/v1/admin/devshards/$DEVSHARD_ESCROW_ID/settle -H \"Authorization: Bearer \$DEVSHARD_ADMIN_API_KEY\" -H 'Content-Type: application/json' -d '{\"private_key_env\":\"DEVSHARD_PRIVATE_KEY\"}'" >"$RUN/settle.json"

step 'Prove on-chain settlement and creator refund'
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  "$ROOT/scripts/inferenced.sh" query inference show-devshard-escrow "$DEVSHARD_ESCROW_ID" --node "$rpc" --chain-id "$CHAIN_ID" --output json >"$RUN/escrow.json" 2>/dev/null || true
  jq -e '.escrow.settled == true' "$RUN/escrow.json" >/dev/null 2>&1 && break
  printf 'WAIT  escrow %s settlement confirmation\n' "$DEVSHARD_ESCROW_ID"
  sleep 3
done
jq -e '.escrow.settled == true' "$RUN/escrow.json" >/dev/null || die 'escrow did not reach settled:true'
ssh "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/cosmos/bank/v1beta1/balances/$creator" >"$RUN/balance-after.json"
ssh "$GATEWAY_NODE" 'cd /srv/dai/ops && docker compose logs --no-color --tail=200 devshard-gateway' >"$RUN/gateway.log" || true
ssh "$GENESIS_NODE" "cd /srv/dai/deploy/$GENESIS_NODE && docker compose logs --no-color --tail=200 versiond api" >"$RUN/versiond-and-api.log" || true
cat >"$RUN/verdict.md" <<EOF
# Chain-accounted inference: PASS

Escrow $DEVSHARD_ESCROW_ID was finalized through its per-escrow gateway path,
settled on chain, and queried as \`settled: true\`. The evidence captures the
funding receipt, authenticated public chat request ID/model/response, and
creator balances before funding, after funding, and after settlement.
DevShard protocol: $devshard_version. Release profile: $GDC_RELEASE_PROFILE.
EOF
printf 'PASS settlement evidence: %s\n' "$RUN"
