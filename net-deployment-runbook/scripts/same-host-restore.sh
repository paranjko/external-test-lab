#!/usr/bin/env bash
# Preserve the signing minimum at reset; authorize only return to that machine.
set +x
set -Eeuo pipefail
umask 077
die() { printf 'same-host restore: %s\n' "$*" >&2; exit 1; }
# The shape every validator accepts; reset warns on it, never refuses.
validate_tmkms_state() {
  local state_file="$1"
  jq -e '
    type == "object"
    and (keys | sort) == ["block_id","height","round","step"]
    and (.height | type == "string" and test("^[0-9]+$"))
    and (.round | type == "string" and test("^[0-9]+$"))
    and (.step | type == "number" and . == floor and . >= -128 and . <= 127)
    and (.block_id == null or (
      .height == "0" and .round == "0" and .step == 0
      and (.block_id | type == "object")
      and ((.block_id | keys | sort) == ["hash","part_set_header"] or (.block_id | keys | sort) == ["hash","parts"])
      and .block_id.hash == ""
      and ((.block_id.parts // .block_id.part_set_header) as $parts
        | ($parts | keys | sort) == ["hash","total"] and $parts.total == 0 and $parts.hash == "")
    ) or (
      (.block_id | type == "object")
      and (.block_id.hash | type == "string" and test("^[0-9A-Fa-f]{64}$"))
      and ((.block_id.parts // .block_id.part_set_header) as $parts
        | ($parts | type == "object")
        and ($parts.total | type == "number" and . == floor and . >= 0 and . <= 4294967295)
        and ($parts.hash | type == "string" and test("^[0-9A-Fa-f]{64}$")))
    ))
  ' "$state_file" >/dev/null 2>&1
}
validate_reset_binding() {
  jq -e --arg machine "$2" --arg key "$3" --arg chain "$4" '
    .kind=="gdc-same-host-reset" and .schema_version==1 and .machine_sha256==$machine
    and .key_sha256==$key and .chain_id==$chain and .signer_stopped==true
    and (.signing_state.height | test("^[0-9]+$"))' "$1" >/dev/null
}
if [[ "${1:-}" == --remote ]]; then
  action="${2:-}"; node="${3:-}"
  [[ $EUID == 0 && "$node" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die 'invalid Host or sudo authority'
  receipt="/srv/dai/rejoin/$node/reset.json"
  machine="$(sha256sum /etc/machine-id | awk '{print $1}')"
  case "$action" in
    capture)
      mapfile -t signer_ids < <(docker ps -aq --filter "label=com.docker.compose.project=$node" --filter label=com.docker.compose.service=tmkms)
      (( ${#signer_ids[@]} > 0 )) || exit 0
      (( ${#signer_ids[@]} == 1 )) || die 'ambiguous managed signer'
      signer="$(docker inspect "${signer_ids[0]}" | jq -er '.[0].Mounts[] | select(.Destination=="/root/.tmkms" and .Type=="bind") | .Source')"
      [[ "$signer" == "/srv/dai/$node/tmkms" || "$signer" == "/srv/dai/signer/$node/tmkms" ]] || die 'unexpected signer directory'
      chain="$(awk -F= '$1=="CHAIN_ID" {print $2;exit}' "/srv/dai/deploy/$node/.env")"
      [[ "$chain" =~ ^[A-Za-z0-9_-]+$ ]] || die 'missing deployed chain ID'
      mapfile -t stopped_ids < <(docker ps -aq --filter "label=com.docker.compose.project=$node" | xargs -r docker inspect | jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] | IN("node","tmkms")) | .Id')
      (( ${#stopped_ids[@]} > 0 )) || die 'missing managed node/signer'
      docker update --restart=no "${stopped_ids[@]}" >/dev/null
      docker stop --time 30 "${stopped_ids[@]}" >/dev/null
      docker inspect "${stopped_ids[@]}" | jq -e 'all(.[]; .State.Running==false)' >/dev/null || die 'signer stop not confirmed'
      install -d -m 0700 "/srv/dai/rejoin/$node"
      next="$(mktemp "/srv/dai/rejoin/$node/reset.XXXXXX.json")"
      jq -cn --arg machine "$machine" --arg chain "$chain" --arg key "$(sha256sum "$signer/secrets/priv_validator_key.softsign" | awk '{print $1}')" \
        --slurpfile state "$signer/state/priv_validator_state.json" --arg time "$(date -u +%FT%TZ)" \
        '{schema_version:1,kind:"gdc-same-host-reset",machine_sha256:$machine,key_sha256:$key,chain_id:$chain,
          signer_stopped:true,signing_state:$state[0],observed_at:$time}' >"$next"
      [[ ! -f "$receipt" ]] || cp -p "$receipt" "$next.previous"
      install -m 0600 "$next" "$receipt"
      printf 'PASS retained same-Host signer stop and signing minimum\n'
      validate_tmkms_state "$signer/state/priv_validator_state.json" \
        || printf 'NOTICE %s signing state does not match the shape a restore accepts; recovery through gdc host join --restore will refuse until it is resolved\n' "$node"
      ;;
    bind)
      expected_chain="${4:-}"
      signer="/srv/dai/signer/$node/tmkms"
      [[ -f "$receipt" && ! -L "$receipt" && "$(stat -c %u "$receipt")" == 0 ]] || die 'no root-owned reset receipt on this Host'
      key="$(sha256sum "$signer/secrets/priv_validator_key.softsign" | awk '{print $1}')"
      validate_reset_binding "$receipt" "$machine" "$key" "$expected_chain" || die 'reset receipt does not match restored machine, chain and key'
      [[ -z "$(docker ps -q --filter "label=com.docker.compose.project=$node" --filter label=com.docker.compose.service=tmkms)" ]] || die 'signer must remain stopped'
      cat "$receipt"
      ;;
    *) die 'unknown remote operation' ;;
  esac
  exit
fi
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
action="${1:-}"; node="${2:-}"
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die 'invalid SSH alias'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$action" in
  capture)
    ssh -T "$node" "sudo -n bash -s -- --remote capture '$node'" <"${BASH_SOURCE[0]}" ;;
  bind)
    identity="${3:-}"; chain="${4:-}"; output="${5:-}"
    [[ -r "$identity" && "$chain" =~ ^[A-Za-z0-9_-]+$ && -n "$output" ]] || die 'invalid restore binding input'
    ssh -T "$node" "sudo -n bash -s -- --remote bind '$node' '$chain'" <"${BASH_SOURCE[0]}" >"$output"
    jq -e '.kind=="gdc-same-host-reset" and .signer_stopped==true' "$output" >/dev/null || die 'invalid reset readback'
    # Preserve the higher of the retained live signing minimum and the archive.
    jq .signing_state "$output" >"$output.minimum"
    ssh -T "$node" "sudo -n cat '/srv/dai/signer/$node/tmkms/state/priv_validator_state.json'" >"$output.observed"
    if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$output.minimum" --observed "$output.observed" >/dev/null 2>&1; then
      :
    else
      "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$output.observed" --observed "$output.minimum" >/dev/null || die 'conflicting signing minima'
      ssh -T "$node" "sudo -n tee '/srv/dai/signer/$node/tmkms/state/priv_validator_state.json' >/dev/null" <"$output.minimum"
    fi
    # The archive verifier binds the restored secret to this public identity.
    expected_key="$(jq -er .consensus_pubkey "$identity")"
    actual_key="$(ssh -T "$node" "sudo -n bash -s -- '/srv/dai/signer/$node/tmkms/secrets/priv_validator_key.softsign'" <"$ROOT/scripts/tmkms-softsign-public-key.sh")"
    [[ "$expected_key" == "$actual_key" ]] || die 'restored key differs from the archive identity'
    ;;
  *) die 'expected capture or bind' ;;
esac
