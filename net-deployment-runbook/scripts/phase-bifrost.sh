#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
[[ "$action" =~ ^(preview|apply)$ ]] || die 'expected: ops bifrost preview or apply'
[[ $# -eq 1 ]] || die 'ops bifrost accepts exactly one action'
gateway_env="$GENERATED/ops/gateway.env"
[[ -s "$gateway_env" ]] || die 'stable Bifrost requires a rendered official gateway S; deploy gateway first'
port="$(awk -F= '$1 == "DEVSHARD_PORT" {print $2; exit}' "$gateway_env")"
model="$(awk -F= '$1 == "DEVSHARD_MODEL" {print substr($0,index($0,"=")+1); exit}' "$gateway_env")"
[[ "$port" =~ ^[1-9][0-9]{0,4}$ && -n "$model" ]] || die 'rendered gateway S has no valid port/model'
bifrost_port="${GDC_BIFROST_PORT:-9467}"
[[ "$bifrost_port" =~ ^[1-9][0-9]{0,4}$ && "$bifrost_port" -le 65535 \
  && "$bifrost_port" != 9465 && "$bifrost_port" != 9466 && "$bifrost_port" != "$port" ]] \
  || die 'GDC_BIFROST_PORT must be a valid private port distinct from gateway, broker and edge ports'

image='maximhq/bifrost@sha256:5f8215163cea192451f4b2ee5e0b583874ffe9435a5ab733e08c07aaf38ace57'
provider='gonka-s'
# Bifrost's OpenAI transport appends /v1 itself; persisting it here would
# produce /v1/v1/chat/completions against the stable gateway.
upstream="http://127.0.0.1:$port"
run="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/bifrost"
mkdir -p "$run"
preview_file="$run/preview.json"

synthetic_empty_preview() {
  local desired current before_sha desired_sha
  desired="$(jq -cn --arg image "$image" --arg provider "$provider" --arg model "$model" --arg upstream "$upstream" --argjson port "$bifrost_port" \
    '{image:$image,provider:$provider,model:$model,upstream:$upstream,port:$port}' | jq -S -c .)"
  current='{"bootstrap":"empty","provider":null}'
  before_sha="$(printf '%s' "$current" | sha256sum | awk '{print $1}')"
  desired_sha="$(printf '%s' "$desired" | sha256sum | awk '{print $1}')"
  jq -cn --arg host "$GATEWAY_NODE" --arg before "$before_sha" --arg desired_sha "$desired_sha" \
    --argjson current "$current" --argjson desired "$desired" \
    '{schema:"gdc-bifrost-state/1",host:$host,applied:false,current:$current,desired:$desired,before_sha256:$before,desired_sha256:$desired_sha,delta:["bootstrap","provider","provider_key"]}'
}

remote_preview() {
  local command overrides receipt status
  if ! ssh -n "$GATEWAY_NODE" 'sudo test -r /srv/dai/ops/bifrost.env'; then
    # A missing rendered environment is expected before the first managed
    # bootstrap, but it must not hide a reachable untracked Bifrost instance.
    status="$(ssh -n "$GATEWAY_NODE" "curl -sS --connect-timeout 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:$bifrost_port/api/config || true")" \
      || die 'could not determine whether Bifrost is absent before empty-state preview'
    [[ "$status" == 000 ]] \
      || die 'Bifrost has no managed environment but answered locally; refusing synthetic empty-state preview'
    synthetic_empty_preview
    return
  fi
  overrides="$(printf 'BIFROST_IMAGE=%q BIFROST_GONKA_PROVIDER=%q BIFROST_GONKA_MODEL=%q BIFROST_GONKA_BASE_URL=%q BIFROST_PORT=%q' \
    "$image" "$provider" "$model" "$upstream" "$bifrost_port")"
  command="set -Eeuo pipefail; set -a; . /srv/dai/ops/bifrost.env; set +a; $overrides python3 /srv/dai/ops/bifrost-provision.py --preview"
  receipt="$(ssh -T "$GATEWAY_NODE" "sudo bash -c $(printf '%q' "$command")")" \
    || die 'Bifrost current-state preview failed on the managed gateway Host'
  jq -e --arg host "$GATEWAY_NODE" '
    select(
      .schema == "gdc-bifrost-state/1" and .applied == false and
      (.before_sha256 | test("^[0-9a-f]{64}$")) and
      (.desired_sha256 | test("^[0-9a-f]{64}$")) and (.delta | type == "array")
    ) | . + {host:$host}
  ' <<<"$receipt"
}

if [[ "$action" == preview ]]; then
  receipt="$(remote_preview)" || die 'Bifrost preview receipt is invalid'
  printf '%s\n' "$receipt" >"$preview_file"
  receipt_sha="$(sha256sum "$preview_file" | awk '{print $1}')"
  delta_count="$(jq '.delta | length' "$preview_file")"
  jq --arg receipt_sha256 "$receipt_sha" '. + {receipt_sha256:$receipt_sha256}' "$preview_file"
  printf 'READY bifrost preview host=%s delta_fields=%s receipt_sha256=%s\n' "$GATEWAY_NODE" "$delta_count" "$receipt_sha"
  exit 0
fi

[[ -s "$preview_file" ]] || die 'ops bifrost apply requires a retained preview receipt for this GDC run'
receipt_sha="$(sha256sum "$preview_file" | awk '{print $1}')"
delta_count="$(jq '.delta | length' "$preview_file")"
approved_sha="${GDC_BIFROST_APPROVED_PREVIEW_SHA256:-}"
[[ "$approved_sha" =~ ^[0-9a-f]{64}$ && "$approved_sha" == "$receipt_sha" ]] \
  || die 'ops bifrost apply requires GDC_BIFROST_APPROVED_PREVIEW_SHA256 for the retained preview receipt'
expected_before="$(jq -r '.before_sha256' "$preview_file")"
current_receipt="$(remote_preview)" || die 'Bifrost current-state recheck failed before apply'
[[ "$(jq -r '.before_sha256' <<<"$current_receipt")" == "$expected_before" ]] \
  || die 'Bifrost state changed after preview; refusing stale apply'
[[ "$(jq -r '.desired_sha256' <<<"$current_receipt")" == "$(jq -r '.desired_sha256' "$preview_file")" ]] \
  || die 'Bifrost desired configuration changed after preview; refusing stale apply'
if [[ "$delta_count" == 0 ]]; then
  printf 'READY bifrost apply host=%s delta_fields=0 no-change\n' "$GATEWAY_NODE"
  exit 0
fi
export GDC_BIFROST_EXPECTED_STATE_SHA256="$expected_before"
exec "$ROOT/scripts/phase-ops.sh" bifrost
