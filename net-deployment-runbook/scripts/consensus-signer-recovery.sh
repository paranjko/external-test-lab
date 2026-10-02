#!/usr/bin/env bash
# Recovery controller primitives. No Host mutation occurs when sourced.

recovery_address_payload() (
  set -Eeuo pipefail
  local address="$1" expected_prefix="$2" prefix encoded alphabet=qpzry9x8gf2tvdw0s3jn54khce6mua7l
  local character value checksum=1 top index bit accumulator=0 bits=0 count=0 payload=''
  local -a values=() data=() generators=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  [[ "$address" == "${address,,}" && "$address" == *1* ]] || return 1
  prefix="${address%1*}"; encoded="${address##*1}"
  [[ "$prefix" == "$expected_prefix" && ${#encoded} -ge 6 && ${#address} -le 90 ]] || return 1
  for ((index=0; index<${#prefix}; index++)); do
    printf -v value '%d' "'${prefix:index:1}"; values+=("$((value >> 5))")
  done
  values+=(0)
  for ((index=0; index<${#prefix}; index++)); do
    printf -v value '%d' "'${prefix:index:1}"; values+=("$((value & 31))")
  done
  for ((index=0; index<${#encoded}; index++)); do
    character="${encoded:index:1}"
    [[ "$alphabet" == *"$character"* ]] || return 1
    value="${alphabet%%"$character"*}"; value="${#value}"
    values+=("$value"); data+=("$value")
  done
  for value in "${values[@]}"; do
    top=$((checksum >> 25)); checksum=$((((checksum & 0x1ffffff) << 5) ^ value))
    for ((bit=0; bit<5; bit++)); do
      if (((top >> bit) & 1)); then checksum=$((checksum ^ generators[bit])); fi
    done
  done
  ((checksum == 1)) || return 1
  for ((index=0; index<${#data[@]}-6; index++)); do
    accumulator=$((((accumulator << 5) | data[index]) & 65535)); bits=$((bits + 5))
    if ((bits >= 8)); then
      bits=$((bits - 8)); printf -v value '%02x' "$(((accumulator >> bits) & 255))"
      payload+="$value"; count=$((count + 1))
    fi
  done
  ((count == 20 && bits < 5 && (accumulator & ((1 << bits) - 1)) == 0)) || return 1
  printf '%s\n' "$payload"
)

recovery_consensus_address() (
  set -Eeuo pipefail
  local key="$1" temporary
  temporary="$(mktemp)"; trap 'rm -f -- "$temporary"' EXIT
  printf '%s' "$key" | base64 -d >"$temporary" 2>/dev/null || return 1
  [[ "$(wc -c <"$temporary")" -eq 32 && "$(base64 -w0 "$temporary")" == "$key" ]] || return 1
  sha256sum "$temporary" | cut -c1-40 | tr '[:lower:]' '[:upper:]'
)

recovery_verify_intent() (
  set -Eeuo pipefail
  local parent="$1" archive="$2" participant="$3" staking="$4" signing="$5"
  local account operator source target consensus signing_address owner_payload
  account="$(jq -er .participant_address "$archive")"
  operator="$(jq -er .validator.operator_address "$staking")"
  owner_payload="$(recovery_address_payload "$account" gonka)"
  [[ "$owner_payload" == "$(recovery_address_payload "$operator" gonkavaloper)" ]] || return 1
  source="$(jq -er .identity_fingerprints.consensus_pubkey "$parent")"
  target="$(jq -er .identity.consensus_pubkey "$archive")"
  recovery_consensus_address "$source" >/dev/null
  consensus="$(recovery_consensus_address "$target")"
  signing_address="$(jq -er .val_signing_info.address "$signing")"
  [[ "$(recovery_address_payload "$signing_address" gonkavalcons)" == "${consensus,,}" ]] || return 1
  jq -es --arg consensus "$consensus" '
    .[0] as $parent | .[1] as $archive | .[2].participant as $participant |
    .[3].validator as $validator | .[4].val_signing_info as $signing |
    $parent.identity_fingerprints as $identity | $archive.identity.consensus_pubkey as $target |
    select($parent.state == "COMPLETE" and $parent.signer_ever_started == true) |
    select($archive.node_name == $parent.node_name and $archive.participant_address == $identity.participant_address) |
    select($target != $identity.consensus_pubkey) |
    select($participant.address == $archive.participant_address and
      ($participant.validator_key == $identity.consensus_pubkey or $participant.validator_key == $target)) |
    select($validator.consensus_pubkey["@type"] == "/cosmos.crypto.ed25519.PubKey" and $validator.consensus_pubkey.key == $target) |
    select($signing.tombstoned == false and ($validator.jailed | type) == "boolean") |
    {schema_version:1,kind:"gdc-consensus-signer-recovery-intent",parent_run_id:$parent.run_id,
     node_name:$parent.node_name,participant_address:$archive.participant_address,
     previous_consensus_pubkey:$identity.consensus_pubkey,restore_consensus_pubkey:$target,
     consensus_address:$consensus,participant_rebind_required:($participant.validator_key != $target),
     jailed:$validator.jailed,preserve_p2p_node_id:$identity.p2p_node_id,
     preserve_warm_address:$identity.warm_address,activation_authorized:false}
  ' "$parent" "$archive" "$participant" "$staking" "$signing"
)

recovery_request() {
  curl -fsS --connect-timeout 5 --max-time 20 --max-filesize 8388608 "$1"
}

recovery_cli() {
  "$(dirname "${BASH_SOURCE[0]}")/inferenced.sh" "$@"
}

recovery_reconcile_participant() (
  set -Eeuo pipefail
  { set +x; } 2>/dev/null
  umask 077
  local run="$1" observation="$2" operator_home="$3" password_path="$4"
  local node account target previous chain api rpc endpoint current public_url password owner response txhash
  local attempt="$run/participant-rebind-attempt.json" broadcast="$run/participant-rebind-broadcast.json"
  local deadline receipt
  node="$(jq -er .spec.target.node_name "$run/join-profile.v1.json")"
  chain="$(jq -er .spec.network.chain_id "$run/join-profile.v1.json")"
  account="$(jq -er .participant_address "$observation/intent.json")"
  target="$(jq -er .restore_consensus_pubkey "$observation/intent.json")"
  previous="$(jq -er .previous_consensus_pubkey "$observation/intent.json")"
  [[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$account" =~ ^gonka1[a-z0-9]+$ ]] || return 2
  jq -e --arg node "$node" '.node_name == $node' "$observation/intent.json" >/dev/null
  api="$(jq -er .api "$observation/origins.json")"
  rpc="$(jq -er '.rpc[0]' "$observation/origins.json")"
  [[ "$api" =~ ^https://[A-Za-z0-9.-]+$ && "$rpc" =~ ^https://[A-Za-z0-9./_-]+$ ]] || return 2
  # JSON-RPC POST requires the path root, not the bare reverse-proxy prefix.
  rpc="${rpc%/}/"
  endpoint="$api/chain-api/productscience/inference/inference/participant/$account"
  current="$(recovery_request "$endpoint")"
  jq -e --arg account "$account" --arg target "$target" --arg previous "$previous" '
    .participant.address == $account and (.participant.validator_key == $target or .participant.validator_key == $previous)
  ' <<<"$current" >/dev/null || { echo 'participant changed outside recovery' >&2; return 1; }
  if jq -e --arg target "$target" '.participant.validator_key == $target' <<<"$current" >/dev/null; then
    jq -cn --arg account "$account" --arg key "$target" '{participant_address:$account,validator_key:$key,broadcast:false}'
    return
  fi
  export GDC_JOIN_PROFILE="$run/join-profile.v1.json" INFERENCED_HOME="$operator_home"
  if [[ ! -e "$attempt" && ! -L "$attempt" ]]; then
    [[ -f "$password_path" && ! -L "$password_path" && "$(stat -c %u "$password_path")" == "$(id -u)" ]] || return 2
    case "$(stat -c %a "$password_path")" in 400|600) ;; *) return 2 ;; esac
    password="$(<"$password_path")"
    owner="$(printf '%s\n' "$password" | recovery_cli keys show "$node-cold" -a --keyring-backend file)"
    [[ "$owner" == "$account" ]] || { unset password; echo 'operator keyring does not own participant' >&2; return 1; }
    public_url="$(jq -er '.participant.inference_url' <<<"$current")"
    [[ "${public_url%/}" == "https://$(jq -er .spec.target.public_host "$run/join-profile.v1.json")" ]] || {
      unset password; echo 'participant endpoint differs from retained Host' >&2; return 1;
    }
    # Claim before broadcast. A transport failure leaves this marker in place:
    # subsequent calls can read back success but must never broadcast blindly.
    (set -o noclobber; jq -cn --arg account "$account" --arg key "$target" \
      '{participant_address:$account,validator_key:$key,broadcast_outcome:"unknown",automatic_resubmit:false}' >"$attempt")
    sync -f "$attempt"
    if ! response="$(printf '%s\n' "$password" | recovery_cli tx inference submit-new-participant "$public_url" \
      --validator-key "$target" --from "$node-cold" --keyring-backend file --chain-id "$chain" --node "$rpc" \
      --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"; then
      unset password; echo 'rebind outcome unknown; automatic resubmission refused' >&2; return 1
    fi
    unset password
    txhash="$(jq -er '(.tx_response // .) | select(.code == 0) | .txhash | select(test("^[A-Fa-f0-9]{64}$"))' <<<"$response")"
    (set -o noclobber; jq -cn --arg hash "$txhash" --arg account "$account" --arg key "$target" \
      '{txhash:$hash,participant_address:$account,validator_key:$key}' >"$broadcast")
    sync -f "$broadcast"
  fi
  [[ -f "$broadcast" && ! -L "$broadcast" ]] || { echo 'prior rebind outcome unknown; automatic resubmission refused' >&2; return 1; }
  txhash="$(jq -er --arg account "$account" --arg key "$target" '
    select(.participant_address == $account and .validator_key == $key) | .txhash | select(test("^[A-Fa-f0-9]{64}$"))
  ' "$broadcast")"
  deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    if receipt="$(recovery_cli query tx "$txhash" --node "$rpc" --output json 2>/dev/null)" &&
       jq -e '(.tx_response // .) | (.height | tonumber) > 0' <<<"$receipt" >/dev/null; then
      jq -e '(.tx_response // .).code == 0' <<<"$receipt" >/dev/null || { echo 'rebind committed with an error' >&2; return 1; }
      current="$(recovery_request "$endpoint")"
      jq -e --arg account "$account" --arg target "$target" '
        .participant.address == $account and .participant.validator_key == $target
      ' <<<"$current" >/dev/null || { echo 'committed rebind differs from chain readback' >&2; return 1; }
      jq -c --arg hash "$txhash" --arg account "$account" --arg key "$target" \
        '{participant_address:$account,validator_key:$key,txhash:$hash,height:(.tx_response // .).height,broadcast:true}' <<<"$receipt"
      return
    fi
    sleep 2
  done
  echo 'rebind confirmation timed out; retain transaction and do not resubmit' >&2
  return 1
)

recovery_effective_power() (
  set -Eeuo pipefail
  local document="$1" height="$2" key="$3" pending="${4:-false}" temporary address
  [[ "$pending" == true || "$pending" == false ]] || return 1
  [[ "$height" =~ ^[1-9][0-9]*$ ]] || return 1
  temporary="$(mktemp)"
  trap 'rm -f -- "$temporary"' EXIT
  printf '%s' "$key" | base64 -d >"$temporary" 2>/dev/null || return 1
  [[ "$(wc -c <"$temporary")" -eq 32 && "$(base64 -w0 "$temporary")" == "$key" ]] || return 1
  address="$(sha256sum "$temporary" | cut -c1-40 | tr '[:lower:]' '[:upper:]')"
  jq -er --arg height "$height" --arg key "$key" --arg address "$address" --argjson pending "$pending" '
    .result
    | select(.block_height == $height)
    | select((.validators | type) == "array")
    | select((.total | tonumber) == (.validators | length) and
             (.count | tonumber) == (.validators | length))
    | select(([.validators[].address] | unique | length) == (.validators | length))
    | [.validators[] | select(.pub_key.value == $key)]
    | if length == 0 and $pending then 0 else
      select(length == 1) | .[0]
    | select(.address == $address and .pub_key.type == "tendermint/PubKeyEd25519")
    | .voting_power | select(type == "string" and test("^[0-9]+$"))
    | tonumber | select(. > 0 or ($pending and . == 0)) end
  ' "$document"
)

recovery_complete_list() {
  local document="$1" field="$2"
  jq -e --arg field "$field" '
    select((.pagination.next_key // "") == "")
    | .[$field] | select(type == "array")
  ' "$document"
}

recovery_observe_membership() (
  set -Eeuo pipefail
  umask 077
  local run="$1" bootstrap="$2" output="$3" expected actual account target address api item payload
  expected="$(jq -er .spec.network.bootstrap_sha256 "$run/join-profile.v1.json")"
  actual="$(sha256sum "$bootstrap")"; actual="${actual%% *}"
  [[ "$actual" == "$expected" ]] || { echo 'Bootstrap differs from retained profile' >&2; exit 1; }
  account="$(jq -er .participant_address "$run/archive/manifest.json")"
  recovery_address_payload "$account" gonka >/dev/null
  target="$(jq -er .identity.consensus_pubkey "$run/archive/manifest.json")"
  address="$(recovery_consensus_address "$target")"
  api="$(jq -er '[.seeds[].api | select(type == "string" and length > 0)][0]' "$bootstrap")"
  api="${api%/}"
  [[ "$api" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?(/[a-zA-Z0-9._/-]*)?$ ]] || exit 1
  mkdir -m 700 -- "$output"
  recovery_request "$api/chain-api/productscience/inference/inference/participant/$account" >"$output/participant.json"
  recovery_request "$api/chain-api/cosmos/staking/v1beta1/validators?pagination.limit=1000" >"$output/staking-list.json"
  recovery_request "$api/chain-api/cosmos/slashing/v1beta1/signing_infos?pagination.limit=1000" >"$output/signing-list.json"
  recovery_complete_list "$output/staking-list.json" validators |
    jq -e --arg target "$target" '[.[] | select(.consensus_pubkey.key == $target)] |
      select(length == 1) | {validator:.[0]}' >"$output/staking.json"
  recovery_complete_list "$output/signing-list.json" info >"$output/signing-complete.json"
  : >"$output/signing-matches.jsonl"
  while IFS= read -r item; do
    payload="$(recovery_address_payload "$(jq -er .address <<<"$item")" gonkavalcons)"
    if [[ "$payload" == "${address,,}" ]]; then
      printf '%s\n' "$item" >>"$output/signing-matches.jsonl"
    fi
  done < <(jq -c '.[]' "$output/signing-complete.json")
  jq -es 'select(length == 1) | {val_signing_info:.[0]}' "$output/signing-matches.jsonl" >"$output/signing.json"
  recovery_verify_intent "$run/parent-final-receipt.json" "$run/archive/manifest.json" \
    "$output/participant.json" "$output/staking.json" "$output/signing.json" >"$output/intent.json"
  jq -n --arg api "$api" --argjson observed "$(date +%s)" \
    '{api:$api,observed_at_unix:$observed,activation_authorized:false}' >"$output/origins.json"
  # Membership evidence is diagnostic, not permission to activate or unjail.
  jq '{stage:"membership_observed",jailed,participant_rebind_required,activation_authorized:false}' "$output/intent.json"
)

recovery_verify_commit() {
  # Reuse the existing canonical CometBFT verifier; recovery orchestration is Bash.
  python3 "$(dirname "${BASH_SOURCE[0]}")/verify-cometbft-commit.py" "$@"
}

recovery_verify_checkpoint() (
  set -Eeuo pipefail
  local chain="$1" height="$2" key="$3" document verified hash='' current stamp age now before
  shift 3
  [[ $# -eq 3 && "$height" =~ ^[1-9][0-9]*$ ]] || return 1
  now="$(date +%s)"
  for document in "$@"; do
    [[ -f "$document" && ! -L "$document" ]] || return 1
    before="$(sha256sum "$document")" || return 1
    verified="$(recovery_verify_commit "$document" "$chain" "$height" "$key" -)" || return 1
    current="$(jq -er '.header_hash | select(test("^[A-F0-9]{64}$"))' <<<"$verified")" || return 1
    [[ -z "$hash" || "$hash" == "$current" ]] || { echo 'Recovery checkpoints disagree' >&2; exit 1; }
    hash="$current"
    stamp="$(jq -er .result.signed_header.header.time "$document")" || return 1
    [[ "$(sha256sum "$document")" == "$before" ]] || { echo 'Recovery checkpoint changed during verification' >&2; exit 1; }
    stamp="$(date -u -d "$stamp" +%s)" || return 1
    age=$((now - stamp))
    ((age >= -10 && age < 120)) || { echo 'Recovery checkpoint is stale or future-dated' >&2; exit 1; }
  done
  jq -n --arg chain "$chain" --arg height "$height" --arg hash "$hash" \
    '{schema_version:1,kind:"gdc-consensus-signer-recovery-checkpoint",chain_id:$chain,
      height:$height,block_hash:$hash,activation_authorized:false}'
)

recovery_local_request() {
  local node="$1" suffix="$2"
  [[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$suffix" =~ ^(status|commit\?height=[0-9]+)$ ]] || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "curl -fsS --max-time 15 'http://127.0.0.1:26657/$suffix'"
}

recovery_write_boundary() (
  set -Eeuo pipefail
  umask 077
  local checkpoint="$1" archived_state="$2" chain="$3" output="$4" height archived
  [[ -f "$checkpoint" && ! -L "$checkpoint" && -f "$archived_state" && ! -L "$archived_state" ]] || return 1
  height="$(jq -er --arg chain "$chain" '
    select(.kind == "gdc-consensus-signer-recovery-checkpoint" and .chain_id == $chain and
      .activation_authorized == false) | .height | select(type == "string" and test("^[1-9][0-9]*$"))
  ' "$checkpoint")" || return 1
  archived="$(jq -er '.height | select(type == "string" and test("^(0|[1-9][0-9]*)$"))' "$archived_state")" || return 1
  # Bound decimal lengths before arithmetic; never round large integers in jq.
  [[ ${#height} -le 18 && ${#archived} -le 18 ]] || return 1
  ((height > archived)) || { echo 'Recovery checkpoint does not exceed archived signing height' >&2; return 1; }
  # This is an explicit refusal fence, not reconstructed signing history. Its
  # max round/step semantics are qualified against the pinned TMKMS image.
  (set -o noclobber; jq -n --arg height "$height" \
    '{height:$height,round:"2147483647",step:127,block_id:null}' >"$output") || return 1
  sync -f "$output"
)

recovery_prepare_host() (
  set -Eeuo pipefail
  umask 077
  local run="$1" observation="$2" node run_id chain height key_sha destination script
  node="$(jq -er .node_name "$observation/intent.json")" || return 1
  run_id="$(jq -er .run_id "$run/recovery-parent.json")" || return 1
  [[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  jq -e --arg node "$node" --arg run "$run_id" \
    '.run_id == $run and .spec.target.node_name == $node' "$run/join-profile.v1.json" >/dev/null || return 1
  # Validate the checkpoint again immediately before stopping consensus. The
  # evidence collected earlier is not an indefinitely reusable start permit.
  chain="$(jq -er .spec.network.chain_id "$run/join-profile.v1.json")" || return 1
  height="$(jq -er .height "$observation/checkpoint.json")" || return 1
  recovery_verify_checkpoint "$chain" "$height" "$(jq -er .restore_consensus_pubkey "$observation/intent.json")" \
    "$observation/rpc-0-commit.json" "$observation/rpc-1-commit.json" "$observation/local-commit.json" \
    >"$observation/pre-stop-checkpoint.json" || return 1
  recovery_local_request "$node" status >"$observation/pre-stop-status.json" || return 1
  jq -e --arg chain "$chain" --slurpfile intent "$observation/intent.json" '
    .result.node_info.network == $chain and .result.sync_info.catching_up == false and
    .result.node_info.id == $intent[0].preserve_p2p_node_id and
    .result.validator_info.pub_key.value == $intent[0].previous_consensus_pubkey
  ' "$observation/pre-stop-status.json" >/dev/null || return 1
  key_sha="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    'sudo sha256sum /srv/dai/signer/tmkms/secrets/priv_validator_key.softsign')" || return 1
  key_sha="${key_sha%% *}"
  [[ "$key_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
  script="$(dirname "${BASH_SOURCE[0]}")/../02-node/prepare-consensus-signer-recovery.sh"
  destination="/srv/backup/consensus-recovery-$run_id"
  # The remote helper exclusively claims the run before any stop, and refuses
  # retries over partial preparations. Only public hashes cross stdout.
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash -c 'source /dev/stdin; prepare_consensus_signer_recovery \"\$@\"' bash /srv/dai/deploy /srv/backup '$run_id' '$key_sha'" <"$script" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo cat '$destination/prepared.json'" >"$run/host-prepared.json" || return 1
  jq -e --arg run "$run_id" --arg key "$key_sha" '
    .kind == "gdc-consensus-recovery-preparation" and .run_id == $run and
    .previous_softsign_sha256 == $key and .consensus_processes_stopped == true and
    .restart_disabled == true and .activation_authorized == false
  ' "$run/host-prepared.json" >/dev/null || return 1
  printf 'PASS consensus processes stopped; retained backup=%s; signer activation is not authorized\n' "$destination"
)

recovery_validate_prepared_inputs() (
  set -Eeuo pipefail
  local run="$1" observation="$2" run_id node expected actual key source_directory
  run_id="$(jq -er .run_id "$run/recovery-parent.json")" || return 1
  node="$(jq -er .node_name "$observation/intent.json")" || return 1
  [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || return 1
  jq -e --arg run "$run_id" '
    .kind == "gdc-consensus-recovery-preparation" and .run_id == $run and
    .consensus_processes_stopped == true and .restart_disabled == true and
    .activation_authorized == false
  ' "$run/host-prepared.json" >/dev/null || return 1
  expected="$(jq -er .archive_sha256 "$run/recovery-parent.json")" || return 1
  actual="$(sha256sum "$run/restore-validator-backup.tar")" || return 1
  [[ "${actual%% *}" == "$expected" ]] || { echo 'Recovery archive changed after validation' >&2; return 1; }
  key="$run/archive/remote-state/tmkms/secrets/priv_validator_key.softsign"
  [[ -f "$key" && ! -L "$key" && "$(readlink -f "$key")" == "$key" ]] || return 1
  source_directory="$(dirname "${BASH_SOURCE[0]}")"
  actual="$("$source_directory/tmkms-softsign-public-key.sh" "$key")" || return 1
  expected="$(jq -er .restore_consensus_pubkey "$observation/intent.json")" || return 1
  [[ "$actual" == "$expected" ]] || { echo 'Extracted signer differs from recovery intent' >&2; return 1; }
  jq -n --arg node "$node" --arg run "$run_id" --arg key "$actual" \
    '{node_name:$node,run_id:$run,consensus_pubkey:$key,activation_authorized:false}'
)

recovery_install_host() (
  set -Eeuo pipefail
  { set +x; } 2>/dev/null
  umask 077
  local run="$1" observation="$2" binding node run_id target destination source_directory file local_file
  binding="$(recovery_validate_prepared_inputs "$run" "$observation")" || return 1
  node="$(jq -er .node_name <<<"$binding")" || return 1
  run_id="$(jq -er .run_id <<<"$binding")" || return 1
  target="$(jq -er .consensus_pubkey <<<"$binding")" || return 1
  [[ "$target" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  destination="/srv/backup/consensus-recovery-$run_id"
  source_directory="$(dirname "${BASH_SOURCE[0]}")"
  recovery_write_boundary "$observation/checkpoint.json" \
    "$run/archive/remote-state/tmkms/state/priv_validator_state.json" \
    "$(jq -er .spec.network.chain_id "$run/join-profile.v1.json")" "$run/recovery-boundary.json" || return 1
  # Exclusive, root-owned destination exists only after preparation. No key,
  # password or mnemonic is placed in process arguments or command output.
  for file in install-consensus-signer.sh tmkms-softsign-public-key.sh replacement.softsign boundary.json; do
    case "$file" in
      install-consensus-signer.sh) local_file="$source_directory/../02-node/$file" ;;
      tmkms-softsign-public-key.sh) local_file="$source_directory/$file" ;;
      replacement.softsign) local_file="$run/archive/remote-state/tmkms/secrets/priv_validator_key.softsign" ;;
      boundary.json) local_file="$run/recovery-boundary.json" ;;
    esac
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
      "sudo bash -c 'set -Eeuo pipefail; umask 077; set -o noclobber; test -d \"\$1\"; test ! -L \"\$1\"; cat >\"\$1/\$2\"; sync -f \"\$1/\$2\"' bash '$destination' '$file'" \
      <"$local_file" || return 1
  done
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash '$destination/install-consensus-signer.sh' /srv/dai/deploy '$destination' '$destination/replacement.softsign' '$destination/boundary.json' '$target' '$destination/tmkms-softsign-public-key.sh'" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash '$destination/install-consensus-signer.sh' --recreate-stopped /srv/dai/deploy '$destination' '$destination/tmkms-softsign-public-key.sh'" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo cat '$destination/recreated.json'" >"$run/host-recreated.json" || return 1
  jq -e --arg run "$run_id" --arg target "$target" '
    .kind == "gdc-consensus-containers-recreated" and .run_id == $run and
    .consensus_pubkey == $target and .activation_authorized == false
  ' "$run/host-recreated.json" >/dev/null || return 1
  printf 'PASS restored signer installed; Core and TMKMS remain stopped\n'
)

recovery_record_transition() (
  set -Eeuo pipefail
  umask 077
  local run="$1" state="$2" evidence="$3" state_file="$4" outcome=in_progress policy=manual_recovery input sha
  case "$state" in
    MEMBERSHIP_RECONCILED|SIGNER_FENCE_VERIFIED|SIGNER_ACTIVATING|SIGNER_ACTIVE_VERIFIED|RECOVERY_ARCHIVE_VERIFIED) ;;
    COMPLETE) outcome=succeeded; policy=resume_same_run ;;
    *) echo 'Unsupported consensus recovery transition' >&2; return 1 ;;
  esac
  [[ -f "$evidence" && ! -L "$evidence" && -f "$state_file" && ! -L "$state_file" ]] || return 1
  sha="$(sha256sum "$evidence")" || return 1
  input="$(mktemp "$run/.recovery-transition.XXXXXX")" || return 1
  trap 'rm -f -- "$input"' EXIT
  jq --arg state "$state" --arg outcome "$outcome" --arg policy "$policy" --arg sha "${sha%% *}" \
    --slurpfile signing "$state_file" '
    .state = $state | .outcome = $outcome | .resume_policy = $policy |
    .signer_ever_started = true |
    .tmkms_state = {height:($signing[0].height | tonumber),round:($signing[0].round | tonumber),
      step:($signing[0].step | tonumber),block_id:($signing[0].block_id.hash // "" | ascii_downcase)} |
    .evidence += [{kind:"consensus_recovery",sha256:$sha}]
  ' "$run/initial-transition.json" >"$input" || return 1
  "$(dirname "${BASH_SOURCE[0]}")/record-join-receipt.sh" --receipt-dir "$run/receipts" --input "$input"
)

recovery_authorize_activation() (
  set -Eeuo pipefail
  umask 077
  local run="$1" observation="$2" bootstrap="$3" output="$4" chain key height index power previous_power='' verified hash='' current stamp now
  local -a roots
  jq -e --slurpfile parent "$run/recovery-parent.json" --slurpfile profile "$run/join-profile.v1.json" '
    .exclusive_signer_confirmed == true and .run_id == $parent[0].run_id and
    .archive_sha256 == $parent[0].archive_sha256 and .node_name == $profile[0].spec.target.node_name
  ' "$run/owner-authority.json" >/dev/null || return 1
  recovery_observe_membership "$run" "$bootstrap" "$output" >/dev/null || return 1
  jq -e '.jailed == false and .participant_rebind_required == false' "$output/intent.json" >/dev/null || {
    echo 'Restored key is jailed or participant binding is not reconciled; signer remains stopped' >&2; return 1;
  }
  chain="$(jq -er .spec.network.chain_id "$run/join-profile.v1.json")" || return 1
  key="$(jq -er .restore_consensus_pubkey "$output/intent.json")" || return 1
  mapfile -t roots <"$observation/rpc-origins.txt"
  [[ ${#roots[@]} -eq 2 && "${roots[0]}" != "${roots[1]}" ]] || return 1
  for index in 0 1; do
    [[ "${roots[index]}" =~ ^https://[A-Za-z0-9./:_-]+$ ]] || return 1
    recovery_request "${roots[index]}/status" >"$output/rpc-$index-status.json" || return 1
  done
  height="$(jq -ers --arg chain "$chain" '
    select(length == 2 and all(.[]; .result.node_info.network == $chain and .result.sync_info.catching_up == false)) |
    [.[] | .result.sync_info.latest_block_height | select(test("^[1-9][0-9]{0,17}$")) | tonumber] |
    select(length == 2) | min - 1 | select(. > 0) | tostring' "$output/rpc-0-status.json" "$output/rpc-1-status.json")" || return 1
  for index in 0 1; do
    recovery_request "${roots[index]}/commit?height=$height" >"$output/rpc-$index-commit.json" || return 1
    verified="$(recovery_verify_commit "$output/rpc-$index-commit.json" "$chain" "$height" "$key" -)" || return 1
    current="$(jq -er .header_hash <<<"$verified")" || return 1
    [[ "$current" =~ ^[A-F0-9]{64}$ && ( -z "$hash" || "$hash" == "$current" ) ]] || return 1
    hash="$current"
    stamp="$(jq -er .result.signed_header.header.time "$output/rpc-$index-commit.json")" || return 1
    stamp="$(date -u -d "$stamp" +%s)" || return 1
    now="$(date +%s)"
    ((now - stamp >= -10 && now - stamp < 120)) || return 1
    recovery_request "${roots[index]}/validators?height=$height&per_page=100" >"$output/rpc-$index-validators.json" || return 1
    power="$(recovery_effective_power "$output/rpc-$index-validators.json" "$height" "$key" true)" || return 1
    [[ -z "$previous_power" || "$power" == "$previous_power" ]] || return 1
    previous_power="$power"
  done
  now="$(date +%s)"
  jq -e --arg height "$height" --arg key "$key" --arg hash "$hash" --argjson now "$now" --argjson power "$power" \
    --slurpfile boundary "$run/recovery-boundary.json" --slurpfile parent "$run/recovery-parent.json" '
    select(.kind == "gdc-consensus-containers-recreated" and .run_id == $parent[0].run_id and
      .consensus_pubkey == $key and .activation_authorized == false) |
    select(($height | tonumber) >= ($boundary[0].height | tonumber)) |
    {kind:"gdc-consensus-recovery-activation",run_id,consensus_pubkey,images,
      activation_authorized:true,exclusive_signer_confirmed:true,checkpoint_height:$height,
      effective_voting_power:$power,validation_pending:true,
      checkpoint_hash:$hash,issued_at_unix:$now,expires_at_unix:($now+60)}
  ' "$run/host-recreated.json" >"$output/activation.json" || return 1
  sync -f "$output/activation.json"
)

recovery_activate_host() (
  set -Eeuo pipefail
  umask 077
  local run="$1" authorization_directory="$2" node run_id destination
  node="$(jq -er .spec.target.node_name "$run/join-profile.v1.json")" || return 1
  run_id="$(jq -er .run_id "$run/recovery-parent.json")" || return 1
  [[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  destination="/srv/backup/consensus-recovery-$run_id"
  recovery_record_transition "$run" SIGNER_ACTIVATING "$authorization_directory/activation.json" \
    "$run/recovery-boundary.json" >/dev/null || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash -c 'set -Eeuo pipefail; umask 077; set -o noclobber; cat >\"\$1/activation.json\"; sync -f \"\$1\"' bash '$destination'" \
    <"$authorization_directory/activation.json" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash '$destination/install-consensus-signer.sh' --activate /srv/dai/deploy '$destination' '$destination/tmkms-softsign-public-key.sh' '$destination/activation.json'" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo cat '$destination/started.json'" >"$run/host-started.json" || return 1
  jq -e --arg run "$run_id" --slurpfile authorized "$authorization_directory/activation.json" '
    .kind == "gdc-consensus-recovery-started" and .run_id == $run and
    .consensus_pubkey == $authorized[0].consensus_pubkey and
    .restart_enabled == false and .signing_verified == false
  ' "$run/host-started.json" >/dev/null || return 1
)

recovery_stage() {
  # A separate shell preserves errexit even when a caller checks our exit code
  # in `if` or `||`; Bash otherwise disables it throughout nested functions.
  bash -Eeuo pipefail -c 'source "$1"; shift; "$@"' bash "${BASH_SOURCE[0]}" "$@"
}

recovery_validation_sample() (
  set -Eeuo pipefail
  local run="$1" observation="$2" output="$3" node chain key address api height epoch effective index hash='' current power old_power='' verified
  local -a roots
  mkdir -m 700 "$output"
  node="$(jq -er .node_name "$observation/intent.json")"
  key="$(jq -er .restore_consensus_pubkey "$observation/intent.json")"
  address="$(recovery_consensus_address "$key")"
  chain="$(jq -er .spec.network.chain_id "$run/join-profile.v1.json")"
  api="$(jq -er .api "$observation/origins.json")"
  [[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$api" =~ ^https://[A-Za-z0-9./:_-]+$ ]] || return 1
  mapfile -t roots <"$observation/rpc-origins.txt"
  [[ ${#roots[@]} -eq 2 ]] || return 1
  recovery_request "$api/chain-api/productscience/inference/inference/current_epoch_group_data" >"$output/epoch-before.json"
  epoch="$(jq -er '.epoch_group_data.epoch_index | select(test("^[0-9]{1,15}$"))' "$output/epoch-before.json")"
  effective="$(jq -er '.epoch_group_data.effective_block_height | select(test("^[0-9]{1,15}$"))' "$output/epoch-before.json")"
  recovery_local_request "$node" status >"$output/local-status.json"
  jq -e --arg key "$key" --slurpfile intent "$observation/intent.json" '
    .result.validator_info.pub_key.value == $key and
    .result.node_info.id == $intent[0].preserve_p2p_node_id' "$output/local-status.json" >/dev/null
  for index in 0 1; do
    [[ "${roots[index]}" =~ ^https://[A-Za-z0-9./:_-]+$ ]] || return 1
    recovery_request "${roots[index]}/status" >"$output/rpc-$index-status.json"
  done
  height="$(jq -ers --arg chain "$chain" '
    select(length == 3 and all(.[]; .result.node_info.network == $chain and .result.sync_info.catching_up == false)) |
    [.[] | .result.sync_info.latest_block_height | select(test("^[1-9][0-9]{0,14}$")) | tonumber] |
    select(length == 3) | min - 1 | select(. > 0) | tostring' "$output/local-status.json" "$output/rpc-0-status.json" "$output/rpc-1-status.json")"
  ((height >= effective)) || return 1
  jq -e --arg height "$height" '($height | tonumber) > (.checkpoint_height | tonumber)' \
    "$run/activation-observation/activation.json" >/dev/null
  for index in 0 1; do
    recovery_request "${roots[index]}/validators?height=$height&per_page=100" >"$output/rpc-$index-validators.json"
    power="$(recovery_effective_power "$output/rpc-$index-validators.json" "$height" "$key")"
    [[ -z "$old_power" || "$old_power" == "$power" ]] || return 1
    old_power="$power"
    recovery_request "${roots[index]}/commit?height=$height" >"$output/rpc-$index-commit.json"
    verified="$(recovery_verify_commit "$output/rpc-$index-commit.json" "$chain" "$height" "$key" "$address")"
    current="$(jq -er 'select(.signed == true) | .header_hash' <<<"$verified")"
    [[ "$current" =~ ^[A-F0-9]{64}$ && ( -z "$hash" || "$hash" == "$current" ) ]] || return 1
    hash="$current"
  done
  recovery_request "$api/chain-api/productscience/inference/inference/current_epoch_group_data" >"$output/epoch-after.json"
  jq -e --arg epoch "$epoch" --arg effective "$effective" '
    .epoch_group_data.epoch_index == $epoch and .epoch_group_data.effective_block_height == $effective
  ' "$output/epoch-after.json" >/dev/null
  jq -n --arg height "$height" --arg epoch "$epoch" --arg key "$key" --arg hash "$hash" --argjson power "$power" \
    '{height:$height,epoch:$epoch,consensus_pubkey:$key,block_hash:$hash,voting_power:$power,signature_verified:true}'
)

recovery_wait_validating() (
  set -Eeuo pipefail
  umask 077
  local run="$1" observation="$2" deadline=$((SECONDS + 1800)) attempt=0 sample first_epoch='' count=0 elapsed_start=$SECONDS
  local validation="${3:-$1/validation}"
  mkdir -m 700 "$validation"
  : >"$validation/signatures.jsonl"
  while ((SECONDS < deadline)); do
    attempt=$((attempt + 1))
    sample="$validation/attempt-$attempt"
    if recovery_stage recovery_validation_sample "$run" "$observation" "$sample" \
        >"$validation/sample.tmp" 2>"$validation/last-error.txt"; then
      jq -cs --slurpfile sample "$validation/sample.tmp" \
        '. + $sample | unique_by(.height)' "$validation/signatures.jsonl" >"$validation/signatures.tmp"
      jq -c '.[]' "$validation/signatures.tmp" >"$validation/signatures.jsonl"
      first_epoch="$(jq -rs 'group_by(.epoch) | map(select(length >= 3) | .[0].epoch | tonumber) |
        if length > 0 then min else empty end' "$validation/signatures.jsonl")"
      if [[ -z "$first_epoch" ]]; then
        first_epoch="$(jq -rs 'map(.epoch | tonumber) | max' "$validation/signatures.jsonl")"
      fi
      count="$(jq -rs --arg epoch "$first_epoch" '[.[] | select(.epoch == $epoch)] | length' "$validation/signatures.jsonl")"
      if jq -es --arg epoch "$first_epoch" '
          ([.[] | select(.epoch == $epoch)] | length) >= 3 and
          any(.[]; (.epoch | tonumber) > ($epoch | tonumber))
        ' "$validation/signatures.jsonl" >/dev/null; then
        jq -s '{verdict:"VALIDATING",consensus_pubkey:.[0].consensus_pubkey,
          signed_blocks:.,epoch_transition_verified:true}' "$validation/signatures.jsonl" \
          >"$validation/result.json"
        sync -f "$validation"
        printf 'PASS VALIDATING: three new canonical signatures and continued signing after epoch transition\n'
        return
      fi
    fi
    printf 'WAIT consensus verification elapsed=%ss remaining=%ss first_epoch=%s signatures_in_first_epoch=%s attempt=%s\n' \
      "$((SECONDS - elapsed_start))" "$((deadline - SECONDS))" "${first_epoch:-pending}" "$count" "$attempt"
    sleep 15
  done
  echo 'INCONCLUSIVE consensus recovery did not prove VALIDATING within 1800s; retain evidence and inspect signer' >&2
  return 2
)

recovery_update_operator_identity() (
  set -Eeuo pipefail
  umask 077
  local run="$1" identity="$2" observation="$3" temporary
  [[ -f "$identity" && ! -L "$identity" ]] || return 1
  # Preserve the current warm and P2P identity. The older archive supplies
  # only the consensus key, never its unrelated operator identity metadata.
  jq -e --slurpfile intent "$observation/intent.json" '
    .node_name == $intent[0].node_name and
    .node_id == $intent[0].preserve_p2p_node_id and
    .warm_address == $intent[0].preserve_warm_address and
    (.consensus_pubkey == $intent[0].previous_consensus_pubkey or
     .consensus_pubkey == $intent[0].restore_consensus_pubkey)
  ' "$identity" >/dev/null || return 1
  if [[ ! -e "$run/operator-identity-before.json" && ! -L "$run/operator-identity-before.json" ]]; then
    (set -o noclobber; cat "$identity" >"$run/operator-identity-before.json") || return 1
    sync -f "$run/operator-identity-before.json" || return 1
  fi
  temporary="$(mktemp "$(dirname "$identity")/.recovered-identity.XXXXXX")" || return 1
  trap 'rm -f -- "$temporary"' EXIT
  jq --slurpfile intent "$observation/intent.json" \
    '.consensus_pubkey = $intent[0].restore_consensus_pubkey' "$identity" >"$temporary" || return 1
  sync -f "$temporary" || return 1
  mv -f -- "$temporary" "$identity" || return 1
  sync -f "$(dirname "$identity")"
)

recovery_continue_installed() (
  set -Eeuo pipefail
  umask 077
  local run="$1" bootstrap="$2" operator_home="$3" password_file="$4"
  local binding node run_id destination evidence source_directory
  binding="$(recovery_validate_prepared_inputs "$run" "$run/preparation-observation")" || return 1
  node="$(jq -er .node_name <<<"$binding")"
  run_id="$(jq -er .run_id <<<"$binding")"
  destination="/srv/backup/consensus-recovery-$run_id"
  evidence="$(mktemp -d "$run/installed-continuation.XXXXXX")"
  source_directory="$(dirname "${BASH_SOURCE[0]}")"
  # Only a completed installation with no activation attempt can continue.
  # Never reinstall the key or rewrite its signing boundary.
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash -c 'set -Eeuo pipefail; test ! -e \"\$1/activation-claim\"; test ! -e \"\$1/activation.json\"; test ! -e \"\$1/started.json\"; cat \"\$1/installed.json\"' bash '$destination'" \
    >"$evidence/installed.json" || return 1
  jq -e --argjson binding "$binding" --slurpfile boundary "$run/recovery-boundary.json" '
    .kind == "gdc-consensus-signer-installed" and .run_id == $binding.run_id and
    .consensus_pubkey == $binding.consensus_pubkey and .boundary == $boundary[0] and
    .activation_authorized == false' "$evidence/installed.json" >/dev/null || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo bash -c 'source /dev/stdin; recreate_consensus_stopped \"\$@\"' bash /srv/dai/deploy '$destination' '$destination/tmkms-softsign-public-key.sh'" \
    <"$source_directory/../02-node/install-consensus-signer.sh" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$node" \
    "sudo cat '$destination/recreated.json'" >"$run/host-recreated.json" || return 1
  recovery_finish_prepared "$run" "$bootstrap" "$operator_home" "$password_file"
)

recovery_execute() (
  set -Eeuo pipefail
  local run="$1" bootstrap="$2" operator_home="$3" password_file="$4"
  [[ -f "$run/owner-authority.json" && ! -L "$run/owner-authority.json" ]] || return 1
  jq -e --slurpfile parent "$run/recovery-parent.json" \
    --slurpfile profile "$run/join-profile.v1.json" '
    .exclusive_signer_confirmed == true and .run_id == $parent[0].run_id and
    .archive_sha256 == $parent[0].archive_sha256 and .node_name == $profile[0].spec.target.node_name
  ' "$run/owner-authority.json" >/dev/null || return 1
  recovery_stage recovery_observe "$run" "$bootstrap" "$run/preparation-observation" || return 1
  recovery_stage recovery_prepare_host "$run" "$run/preparation-observation" || return 1
  recovery_stage recovery_install_host "$run" "$run/preparation-observation" || return 1
  recovery_finish_prepared "$run" "$bootstrap" "$operator_home" "$password_file"
)

recovery_resume_fenced() (
  set -Eeuo pipefail
  umask 077
  local run="$1" bootstrap="$2" output
  [[ ! -e "$run/activation-observation/activation.json" ]] || return 1
  output="$run/activation-recheck-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  recovery_stage recovery_authorize_activation "$run" "$run/preparation-observation" "$bootstrap" "$output" || return 1
  # Keep every failed observation. Only the successful permit is made the
  # canonical lower boundary for subsequent signature verification.
  (set -o noclobber; cat "$output/activation.json" >"$run/activation-observation/activation.json") || return 1
  sync -f "$run/activation-observation/activation.json" || return 1
  recovery_stage recovery_activate_host "$run" "$output"
)

recovery_finish_prepared() (
  set -Eeuo pipefail
  local run="$1" bootstrap="$2" operator_home="$3" password_file="$4"
  recovery_stage recovery_reconcile_participant "$run" "$run/preparation-observation" "$operator_home" "$password_file" \
    >"$run/participant-reconciled.json" || return 1
  recovery_stage recovery_record_transition "$run" MEMBERSHIP_RECONCILED "$run/participant-reconciled.json" "$run/recovery-boundary.json" >/dev/null || return 1
  recovery_stage recovery_record_transition "$run" SIGNER_FENCE_VERIFIED "$run/host-recreated.json" "$run/recovery-boundary.json" >/dev/null || return 1
  recovery_stage recovery_authorize_activation "$run" "$run/preparation-observation" "$bootstrap" "$run/activation-observation" || return 1
  recovery_stage recovery_activate_host "$run" "$run/activation-observation" || return 1
  printf 'READY recovered consensus processes started; canonical signatures are not yet verified\n'
)

recovery_observe() (
  set -Eeuo pipefail
  local run="$1" bootstrap="$2" output="$3" node chain key height index url power previous_power=''
  local -a roots
  recovery_observe_membership "$run" "$bootstrap" "$output" >/dev/null
  jq -e '.jailed == false' "$output/intent.json" >/dev/null || {
    echo 'Target validator is jailed; no implicit unjail is permitted' >&2; exit 1;
  }
  jq -er '[.seeds[].rpc | sub("/$"; "") |
    select(test("^https://[a-zA-Z0-9.-]+(:[0-9]+)?(/[a-zA-Z0-9._/-]*)?$")) |
    {url:.,host:(capture("^https://(?<host>[^/:]+)").host | ascii_downcase)}] |
    unique_by(.host) | select(length >= 2) | .[:2][].url' "$bootstrap" >"$output/rpc-origins.txt"
  mapfile -t roots <"$output/rpc-origins.txt"
  [[ ${#roots[@]} -eq 2 ]] || exit 1
  node="$(jq -er .node_name "$output/intent.json")"
  chain="$(jq -er .spec.network.chain_id "$run/join-profile.v1.json")"
  key="$(jq -er .restore_consensus_pubkey "$output/intent.json")"
  recovery_local_request "$node" status >"$output/local-status.json"
  jq -e --slurpfile intent "$output/intent.json" '
    .result.validator_info.pub_key.value == $intent[0].previous_consensus_pubkey and
    .result.node_info.id == $intent[0].preserve_p2p_node_id' "$output/local-status.json" >/dev/null
  for index in 0 1; do
    recovery_request "${roots[index]}/status" >"$output/rpc-$index-status.json"
  done
  height="$(jq -ers --arg chain "$chain" '
    select(length == 3 and all(.[]; .result.node_info.network == $chain and
      .result.sync_info.catching_up == false)) |
    [.[] | .result.sync_info.latest_block_height | select(test("^[1-9][0-9]*$")) | tonumber] |
    select(length == 3) | min - 1 | select(. > 0) | tostring' "$output/local-status.json" "$output/rpc-0-status.json" "$output/rpc-1-status.json")"
  for index in 0 1; do
    url="${roots[index]}"
    recovery_request "$url/commit?height=$height" >"$output/rpc-$index-commit.json"
    recovery_request "$url/validators?height=$height&per_page=100" >"$output/rpc-$index-validators.json"
    power="$(recovery_effective_power "$output/rpc-$index-validators.json" "$height" "$key")"
    [[ -z "$previous_power" || "$previous_power" == "$power" ]] || exit 1
    previous_power="$power"
  done
  recovery_local_request "$node" "commit?height=$height" >"$output/local-commit.json"
  recovery_verify_checkpoint "$chain" "$height" "$key" "$output/rpc-0-commit.json" \
    "$output/rpc-1-commit.json" "$output/local-commit.json" >"$output/checkpoint.json"
  jq --argjson power "$power" '. + {effective_voting_power:$power}' "$output/intent.json" >"$output/intent.tmp"
  mv "$output/intent.tmp" "$output/intent.json"
  jq --arg rpc0 "${roots[0]}" --arg rpc1 "${roots[1]}" '. + {rpc:[$rpc0,$rpc1]}' \
    "$output/origins.json" >"$output/origins.tmp"
  mv "$output/origins.tmp" "$output/origins.json"
  jq -n --arg height "$height" '{stage:"observed",height:$height,activation_authorized:false}'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -ne 4 || "$1" != observe ]]; then
    echo 'usage: consensus-signer-recovery.sh observe RUN BOOTSTRAP OUTPUT' >&2
    exit 2
  fi
  recovery_observe "$2" "$3" "$4"
fi
