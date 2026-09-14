#!/usr/bin/env bash
# Local admission control for network recovery. No SSH, Docker, chain or signer
# commands here; a phase needs a registered handler before recovery_main can PASS.

set -Eeuo pipefail

RECOVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECOVERY_ROOT="$(cd "$RECOVERY_LIB_DIR/.." && pwd)"

# shellcheck source=scripts/lib.sh
if ! declare -F init_gdc_paths >/dev/null; then
  # shellcheck disable=SC1091 # resolved beside this library at runtime
  source "$RECOVERY_LIB_DIR/lib.sh"
fi

declare -Ag RECOVERY_REGISTERED_HANDLERS=()

# Bounds for inspect's read-only bounded SSH observation (HF-05 block 1).
# Env-overridable only so offline tests can run fast and deterministic;
# production operators should keep the defaults.
RECOVERY_SSH_CONNECT_TIMEOUT_SECONDS="${RECOVERY_SSH_CONNECT_TIMEOUT_SECONDS:-5}"
RECOVERY_SSH_COMMAND_TIMEOUT_SECONDS="${RECOVERY_SSH_COMMAND_TIMEOUT_SECONDS:-10}"
RECOVERY_SSH_MAX_OUTPUT_BYTES="${RECOVERY_SSH_MAX_OUTPUT_BYTES:-1048576}"
RECOVERY_INSPECT_MAX_EVIDENCE_AGE_SECONDS="${RECOVERY_INSPECT_MAX_EVIDENCE_AGE_SECONDS:-300}"
RECOVERY_INSPECT_REOBSERVE_DELAY_SECONDS="${RECOVERY_INSPECT_REOBSERVE_DELAY_SECONDS:-2}"
RECOVERY_INSPECT_MAX_VALIDATOR_PAGES="${RECOVERY_INSPECT_MAX_VALIDATOR_PAGES:-64}"
RECOVERY_REMOTE_COMPOSE_DIR_TEMPLATE="${RECOVERY_REMOTE_COMPOSE_DIR_TEMPLATE:-/srv/dai/deploy/%s}"
RECOVERY_REMOTE_SOURCE_HOME_TEMPLATE="${RECOVERY_REMOTE_SOURCE_HOME_TEMPLATE:-/srv/dai/data/%s/inference}"
RECOVERY_REMOTE_TMKMS_STATE_TEMPLATE="${RECOVERY_REMOTE_TMKMS_STATE_TEMPLATE:-/srv/dai/signer/%s/tmkms/state/priv_validator_state.json}"

recovery_error() { printf 'recovery: %s\n' "$*" >&2; }

recovery_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

recovery_sha256() {
  [[ -f "$1" ]] || return 1
  sha256sum "$1" | awk '{print tolower($1)}'
}

recovery_is_identifier() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

recovery_is_incident() {
  [[ "${1:-}" =~ ^GNK-LAB-[0-9]{4}-[0-9]{4}$ ]]
}

recovery_is_phase() {
  [[ "${1:-}" =~ ^(inspect|prepare|freeze|stage|status|activate|checkpoint|retire|rejoin|resume|verify|abort)$ ]]
}

recovery_is_mutating_phase() {
  case "${1:-}" in
    prepare|freeze|stage|activate|retire|rejoin|resume|abort) return 0 ;;
    verify) [[ "${RECOVERY_SCOPE:-}" == service ]] ;;
    *) return 1 ;;
  esac
}

# Canonical paths only: a symlink could swap the artifact between check and use.
recovery_canonical_input_file() {
  local path="${1:-}" canonical
  [[ "$path" == /* && "$path" != / && -f "$path" && ! -L "$path" ]] || return 1
  canonical="$(realpath "$path" 2>/dev/null)" || return 1
  [[ "$canonical" == "$path" ]]
}

recovery_canonical_directory() {
  local path="${1:-}" canonical
  [[ "$path" == /* && "$path" != / && -d "$path" && ! -L "$path" ]] || return 1
  canonical="$(realpath "$path" 2>/dev/null)" || return 1
  [[ "$canonical" == "$path" ]]
}

recovery_canonical_output_path() {
  local path="${1:-}" parent base canonical_parent canonical
  [[ "$path" == /* && "$path" != / && "$path" != */../* && "$path" != */./* ]] || return 1
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  [[ "$base" != . && "$base" != .. && -d "$parent" && ! -L "$parent" ]] || return 1
  canonical_parent="$(realpath "$parent" 2>/dev/null)" || return 1
  canonical="$canonical_parent/$base"
  [[ "$canonical" == "$path" ]] || return 1
  case "$canonical" in
    /tmp/*|/private/tmp/*|/var/tmp/*) return 1 ;;
  esac
  [[ ! -e "$canonical" && ! -L "$canonical" ]]
}

recovery_require_private_file() {
  local path="$1" mode
  recovery_canonical_input_file "$path" || {
    recovery_error "input is not a canonical regular file: $path"
    return 1
  }
  mode="$(recovery_file_mode "$path")" || return 1
  [[ "$mode" == 600 || "$mode" == 400 ]] || {
    recovery_error "security input must have mode 0600 or 0400: $path"
    return 1
  }
}

recovery_validate_json_schema() {
  local schema="$1" document="$2"
  recovery_canonical_input_file "$document" || {
    recovery_error "JSON document is not a canonical regular file: $document"
    return 1
  }
  [[ -f "$schema" && ! -L "$schema" ]] || {
    recovery_error "required schema is unavailable: $schema"
    return 1
  }
  command -v python3 >/dev/null || {
    recovery_error 'python3 is required for strict recovery schema validation'
    return 1
  }
  python3 -c '
import json, sys
try:
    from jsonschema import Draft202012Validator
    with open(sys.argv[1], "r", encoding="utf-8") as stream:
        schema = json.load(stream)
    with open(sys.argv[2], "r", encoding="utf-8") as stream:
        document = json.load(stream)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER)
    errors = sorted(validator.iter_errors(document), key=lambda e: list(e.path))
    if errors:
        first = errors[0]
        location = ".".join(str(item) for item in first.path) or "<root>"
        raise ValueError(f"{location}: {first.message}")
except Exception as error:
    print(f"recovery schema validation failed: {error}", file=sys.stderr)
    sys.exit(1)
' "$schema" "$document"
}

recovery_manifest_schema() { printf '%s/schemas/recovery-manifest-v1.schema.json\n' "$RECOVERY_ROOT"; }
recovery_receipt_schema() { printf '%s/schemas/recovery-receipt-v1.schema.json\n' "$RECOVERY_ROOT"; }

recovery_validate_manifest() {
  local manifest="$1" host="$2" phase="$3" lifecycle incident role_count
  local matrix_mismatch available_valopers total_power available_power required_power
  recovery_require_private_file "$manifest" || return 1
  recovery_validate_json_schema "$(recovery_manifest_schema)" "$manifest" || return 1
  jq -e --arg host "$host" '
    .schema_version == 1 and .kind == "gdc-network-recovery-manifest"
    and any(.hosts.bindings[]; .host == $host)
  ' "$manifest" >/dev/null || {
    recovery_error "manifest is not bound to host $host"
    return 1
  }
  lifecycle="$(jq -r '.lifecycle.state' "$manifest")"
  if [[ "$phase" == prepare ]]; then
    [[ "$lifecycle" == draft ]] || {
      recovery_error 'prepare requires the preparation draft, not a finalized manifest'
      return 1
    }
  else
    [[ "$lifecycle" == final ]] || {
      recovery_error "phase $phase requires a final immutable manifest"
      return 1
    }
  fi
  incident="$(jq -r '.incident.incident_id' "$manifest")"
  recovery_is_incident "$incident" || {
    recovery_error 'manifest incident identifier is invalid'
    return 1
  }
  role_count="$(jq --arg host "$host" '[.hosts.bindings[] | select(.host == $host)] | length' "$manifest")"
  [[ "$role_count" == 1 ]] || {
    recovery_error "manifest host binding is missing or ambiguous for $host"
    return 1
  }
  # INV-002: the transition key must differ from the participant's old key.
  jq -e '
    .transition.new_transition_consensus == null or (
      .transition.old_participant_consensus.public_key != .transition.new_transition_consensus.public_key
      and .transition.old_participant_consensus.consensus_address != .transition.new_transition_consensus.consensus_address
    )
  ' "$manifest" >/dev/null || {
    recovery_error 'transition old and new consensus keys must differ'
    return 1
  }
  # C1: retirement must exclude only the lost participants. A retired
  # identity can never be the transition key/valoper, nor any host already
  # bound to the return cohort.
  jq -e '
    (.transition.new_transition_consensus.public_key // "no-new-key") as $new_key
    | (.transition.new_transition_consensus.consensus_address // "no-new-addr") as $new_addr
    | (.transition.valoper_address) as $transition_valoper
    | ([.hosts.bindings[] | select(.roles | index("returning")) | .participant
         | select(. != null) | (.account_address, .valoper_address, .participant_address)]) as $cohort
    | all(.retirement.retired_identities[]?;
        (.consensus_keys | all(.[]; .public_key != $new_key and .consensus_address != $new_addr))
        and .valoper_address != $transition_valoper
        and (any([.account_address, .valoper_address, .participant_address][]; . as $a | $cohort | index($a) != null) | not)
      )
  ' "$manifest" >/dev/null || {
    recovery_error 'retired identities must exclude the transition key/valoper and every return-cohort host'
    return 1
  }
  # C2: the transition host can never be a returning host, nor be approved
  # for API/ML service (which resume poc would otherwise be free to enable).
  jq -e '
    (.transition.host) as $transition_host
    | (.hosts.return_order | index($transition_host) == null)
    and (all(.hosts.bindings[] | select(.host == $transition_host);
      (.approved_services // []) | (index("api") == null and index("ml") == null)))
  ' "$manifest" >/dev/null || {
    recovery_error 'the transition host must not be a returning host or approved for API/ML'
    return 1
  }
  # E5 (HF-01): counting commit-H signers alone undercounts available power,
  # erring toward an unnecessary drastic recovery; union in controlled validators.
  matrix_mismatch="$(jq -r '
    ([.validator_sets.next.validators[].valoper_address] | sort) as $set
    | ([.validator_sets.signer_control_matrix[].valoper_address] | sort) as $matrix
    | ($set != $matrix)
  ' "$manifest")" || return 1
  [[ "$matrix_mismatch" == false ]] || {
    recovery_error 'every H+1 validator must have exactly one signer-control classification'
    return 1
  }
  available_valopers="$(jq -c '
    ([.chain.commit_h.signatures[] | select(.block_id_flag == 2) | .validator_address | ascii_downcase]) as $signed
    | ([.validator_sets.signer_control_matrix[] | select(.classification == "controlled") | .valoper_address]) as $controlled
    | ([.validator_sets.next.validators[]
         | select((.consensus.consensus_address | ascii_downcase) as $a | $signed | index($a) != null)
         | .valoper_address] + $controlled | unique)
  ' "$manifest")" || return 1
  total_power="$(jq -r '.validator_sets.next.validators[].voting_power' "$manifest" | recovery_sum_power)" || return 1
  available_power="$(jq -r --argjson available "$available_valopers" '
    .validator_sets.next.validators[] | select(.valoper_address as $v | $available | index($v) != null) | .voting_power
  ' "$manifest" | recovery_sum_power)" || return 1
  required_power="$(recovery_strict_required_power "$total_power")" || return 1
  [[ "$available_power" -lt "$required_power" ]] || {
    recovery_error 'original quorum is recoverable under the signer-control matrix; drastic recovery is not justified'
    return 1
  }
  case "$phase${RECOVERY_STEP:+:$RECOVERY_STEP}" in
    activate|checkpoint|retire|resume:handoff)
      jq -e --arg host "$host" '
        .transition.host == $host
        and any(.hosts.bindings[]; .host == $host and (.roles | index("transition")))
      ' "$manifest" >/dev/null \
        || { recovery_error "$phase requires the transition role for $host"; return 1; }
      ;;
    rejoin|resume:signers|resume:poc)
      jq -e --arg host "$host" '
        (.hosts.return_order | index($host)) != null
        and any(.hosts.bindings[]; .host == $host and (.roles | index("returning")))
      ' "$manifest" >/dev/null \
        || { recovery_error "$phase requires the returning role for $host"; return 1; }
      ;;
  esac
}

recovery_manifest_hash() {
  local current
  current="$(recovery_sha256 "$RECOVERY_MANIFEST")" || return 1
  [[ -z "${RECOVERY_MANIFEST_SHA256:-}" || "$current" == "$RECOVERY_MANIFEST_SHA256" ]] || {
    recovery_error 'manifest changed after admission'
    return 1
  }
  printf '%s\n' "$current"
}

recovery_epoch() {
  jq -nr --arg value "$1" '$value | fromdateiso8601' 2>/dev/null
}

# Accepts only an OpenSSH signature over the canonical payload by a manifest-pinned key.
recovery_verify_approval_signature() {
  local approval="$1" manifest="$2" key_id public_key public_key_sha expected_public_key_sha role
  local namespace payload signature allowed action subject approval_host policy_count minimum maximum_age
  local signature_count index canonical_sha trusted_set_sha required_role
  local -A seen_key_ids=() verified_roles=()
  local -a verified_key_ids=()
  namespace="$(jq -er '.approval.signed_payload.namespace' "$approval")" || return 1
  [[ "$namespace" == gdc-network-recovery-v1 ]] || return 1
  action="$(jq -er '.approval.signed_payload.action' "$approval")" || return 1
  subject="$(jq -er '.approval.signed_payload.subject_kind' "$approval")" || return 1
  approval_host="$(jq -er '.approval.signed_payload.host' "$approval")" || return 1
  policy_count="$(jq --arg action "$action" --arg subject "$subject" '
    [.approvals.phase_policies[] | select(.action == $action and .subject_kind == $subject)] | length
  ' "$manifest")" || return 1
  [[ "$policy_count" == 1 ]] || { recovery_error 'approval policy is missing or ambiguous'; return 1; }
  jq -e --arg action "$action" --arg subject "$subject" --arg host "$approval_host" '
    any(.approvals.phase_policies[];
      .action == $action and .subject_kind == $subject and (.allowed_hosts | index($host)) != null)
  ' "$manifest" >/dev/null || { recovery_error 'approval policy does not permit this host'; return 1; }
  minimum="$(jq -er --arg action "$action" --arg subject "$subject" '
    .approvals.phase_policies[] | select(.action == $action and .subject_kind == $subject) | .minimum_signatures
  ' "$manifest")" || return 1
  maximum_age="$(jq -er --arg action "$action" --arg subject "$subject" '
    .approvals.phase_policies[] | select(.action == $action and .subject_kind == $subject) | .maximum_age_seconds
  ' "$manifest")" || return 1
  RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS="$maximum_age"

  jq -e '([.approvals.trusted_approvers[].key_id] | length) == ([.approvals.trusted_approvers[].key_id] | unique | length)' \
    "$manifest" >/dev/null || { recovery_error 'manifest contains duplicate trusted approver key IDs'; return 1; }
  trusted_set_sha="$(jq -cS '.approvals.trusted_approvers' "$manifest" | sha256sum | awk '{print tolower($1)}')"
  jq -e --arg sha "$trusted_set_sha" --argjson minimum "$minimum" '
    .approval.verification.trusted_approver_set_sha256 == $sha
    and .approval.verification.required_signatures == $minimum
  ' "$approval" >/dev/null || { recovery_error 'approval verification metadata is not bound to the manifest policy'; return 1; }

  payload="$(mktemp)"; chmod 600 "$payload"
  jq -cS '.approval.signed_payload' "$approval" >"$payload" || { rm -f "$payload"; return 1; }
  canonical_sha="$(recovery_sha256 "$payload")" || { rm -f "$payload"; return 1; }
  jq -e --arg sha "$canonical_sha" '.approval.canonical_payload_sha256 == $sha' "$approval" >/dev/null \
    || { rm -f "$payload"; recovery_error 'approval canonical payload digest is invalid'; return 1; }

  signature_count="$(jq '.approval.signatures | length' "$approval")" || { rm -f "$payload"; return 1; }
  for ((index = 0; index < signature_count; index++)); do
    key_id="$(jq -er --argjson index "$index" '.approval.signatures[$index].key_id' "$approval")" || { rm -f "$payload"; return 1; }
    # Check the JSON value: a bash variable cannot hold NUL.
    jq -e --argjson index "$index" '
      (.approval.signatures[$index].key_id | (contains("\n") or contains("\r") or (explode | any(. == 0)))) | not
    ' "$approval" >/dev/null \
      || { rm -f "$payload"; recovery_error 'approval signer key_id contains a control character'; return 1; }
    [[ -z "${seen_key_ids[$key_id]:-}" ]] || { rm -f "$payload"; recovery_error 'approval contains a duplicate signer'; return 1; }
    seen_key_ids["$key_id"]=true
    jq -e --argjson index "$index" --arg sha "$canonical_sha" \
      '.approval.signatures[$index].signed_payload_sha256 == $sha' "$approval" >/dev/null \
      || { rm -f "$payload"; recovery_error 'approval signature is bound to another payload'; return 1; }
    [[ "$(jq --arg key "$key_id" '[.approvals.trusted_approvers[] | select(.key_id == $key)] | length' "$manifest")" == 1 ]] \
      || { rm -f "$payload"; recovery_error "approval signer is not uniquely trusted: $key_id"; return 1; }
    public_key="$(jq -er --arg key "$key_id" '.approvals.trusted_approvers[] | select(.key_id == $key) | .public_key' "$manifest")" \
      || { rm -f "$payload"; return 1; }
    # A line break would add a second key for this signer to allowed_signers.
    jq -e --arg key "$key_id" '
      (.approvals.trusted_approvers[] | select(.key_id == $key) | .public_key
        | (contains("\n") or contains("\r") or (explode | any(. == 0)))) | not
    ' "$manifest" >/dev/null \
      || { rm -f "$payload"; recovery_error "trusted approver public key contains a control character: $key_id"; return 1; }
    expected_public_key_sha="$(jq -er --arg key "$key_id" '.approvals.trusted_approvers[] | select(.key_id == $key) | .public_key_sha256' "$manifest")" \
      || { rm -f "$payload"; return 1; }
    public_key_sha="$(printf '%s' "$public_key" | sha256sum | awk '{print tolower($1)}')"
    [[ "$public_key_sha" == "$expected_public_key_sha" ]] \
      || { rm -f "$payload"; recovery_error "trusted approver public key digest is invalid: $key_id"; return 1; }
    role="$(jq -er --arg key "$key_id" '.approvals.trusted_approvers[] | select(.key_id == $key) | .role' "$manifest")" \
      || { rm -f "$payload"; return 1; }
    signature="$(jq -er --argjson index "$index" '.approval.signatures[$index].armored_signature' "$approval")" \
      || { rm -f "$payload"; return 1; }
    allowed="$(mktemp)"; chmod 600 "$allowed"
    printf '%s %s\n' "$key_id" "$public_key" >"$allowed"
    printf '%s\n' "$signature" >"$payload.sig"
    if ! ssh-keygen -Y verify -f "$allowed" -I "$key_id" -n "$namespace" -s "$payload.sig" <"$payload" >/dev/null 2>&1; then
      rm -f "$payload" "$payload.sig" "$allowed"
      recovery_error "approval signature verification failed: $key_id"
      return 1
    fi
    rm -f "$payload.sig" "$allowed"
    verified_key_ids+=("$key_id")
    verified_roles["$role"]=true
  done
  (( ${#verified_key_ids[@]} >= minimum )) || { rm -f "$payload"; recovery_error 'approval signature threshold was not met'; return 1; }
  while IFS= read -r required_role; do
    [[ -n "${verified_roles[$required_role]:-}" ]] || { rm -f "$payload"; recovery_error "approval is missing required role: $required_role"; return 1; }
  done < <(jq -er --arg action "$action" --arg subject "$subject" '
    .approvals.phase_policies[] | select(.action == $action and .subject_kind == $subject) | .required_roles[]
  ' "$manifest")
  local verified_json
  verified_json="$(jq -cn --args '$ARGS.positional' -- "${verified_key_ids[@]}")"
  jq -e --argjson verified "$verified_json" '
    (.approval.verification.verified_key_ids | sort) == ($verified | sort)
  ' "$approval" >/dev/null || { rm -f "$payload"; recovery_error 'approval verified-key metadata does not match cryptographic verification'; return 1; }
  rm -f "$payload"
  return 0
}

recovery_validate_approval() {
  local approval="$1" now not_before not_after expected_action expected_subject expected_subject_sha
  local approval_id nonce
  recovery_require_private_file "$approval" || return 1
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$approval" || return 1
  jq -e --arg run "$RECOVERY_RUN_ID" --arg host "$RECOVERY_HOST" --arg phase "$RECOVERY_PHASE" \
    --arg manifest "$RECOVERY_MANIFEST_SHA256" '
      .receipt_type == "approval" and .run_id == $run and .host == $host
      and .phase == $phase and .manifest_sha256 == $manifest
      and .approval.signed_payload.run_id == $run
      and .approval.signed_payload.host == $host
    ' "$approval" >/dev/null || {
      recovery_error 'approval has a foreign run, host, phase, or manifest binding'
      return 1
    }
  # Early refusal only; recovery_consume_approval claims the marker.
  approval_id="$(jq -er '.approval.signed_payload.approval_id' "$approval")" || return 1
  nonce="$(jq -er '.approval.signed_payload.nonce' "$approval")" || return 1
  ! recovery_approval_already_consumed "$approval_id" "$nonce" || {
    recovery_error 'approval was already consumed in this run'
    return 1
  }
  RECOVERY_PENDING_APPROVAL_ID="$approval_id"
  RECOVERY_PENDING_APPROVAL_NONCE="$nonce"
  export RECOVERY_PENDING_APPROVAL_ID RECOVERY_PENDING_APPROVAL_NONCE
  if [[ "$RECOVERY_PHASE" == resume ]]; then
    jq -e --arg action "resume_$RECOVERY_STEP" '.approval.signed_payload.action == $action' "$approval" >/dev/null \
      || { recovery_error 'approval is bound to another resume step'; return 1; }
  fi
  if [[ "$RECOVERY_PHASE" == verify ]]; then
    jq -e --arg action "verify_$RECOVERY_SCOPE" '.approval.signed_payload.action == $action' "$approval" >/dev/null \
      || { recovery_error 'approval is bound to another verification scope'; return 1; }
  fi
  case "$RECOVERY_PHASE" in
    checkpoint) expected_action=checkpoint_accept ;; resume) expected_action="resume_$RECOVERY_STEP" ;;
    verify) expected_action="verify_$RECOVERY_SCOPE" ;;
    *) expected_action="$RECOVERY_PHASE" ;;
  esac
  if [[ "$RECOVERY_PHASE" == prepare ]]; then
    expected_subject=preparation_draft
    expected_subject_sha="$RECOVERY_MANIFEST_SHA256"
  elif [[ "$RECOVERY_PHASE" == rejoin ]]; then
    expected_subject=checkpoint
    expected_subject_sha="$(recovery_sha256 "$RECOVERY_CHECKPOINT")" || return 1
  else
    expected_subject=final_manifest
    expected_subject_sha="$RECOVERY_MANIFEST_SHA256"
  fi
  jq -e --arg action "$expected_action" --arg subject "$expected_subject" --arg subject_sha "$expected_subject_sha" '
    .approval.signed_payload.action == $action
    and .approval.signed_payload.subject_kind == $subject
    and .approval.signed_payload.subject_sha256 == $subject_sha
  ' "$approval" >/dev/null || {
    recovery_error 'approval action or subject binding is invalid'; return 1;
  }
  # Compare the declared digest independently so a syntactically valid but
  # rebound approval cannot pass admission.
  local declared actual
  declared="$(jq -er '.approval.canonical_payload_sha256' "$approval")" || return 1
  actual="$(jq -cS '.approval.signed_payload' "$approval" | sha256sum | awk '{print tolower($1)}')"
  [[ "$declared" == "$actual" ]] || { recovery_error 'approval canonical payload digest is invalid'; return 1; }
  not_before="$(jq -er '.approval.signed_payload.not_before' "$approval")" || return 1
  not_after="$(jq -er '.approval.signed_payload.expires_at' "$approval")" || return 1
  now="$(date -u +%s)"
  not_before="$(recovery_epoch "$not_before")" || return 1
  not_after="$(recovery_epoch "$not_after")" || return 1
  (( now >= not_before && now <= not_after && not_after > not_before )) || {
    recovery_error 'approval is not currently valid'
    return 1
  }
  recovery_verify_approval_signature "$approval" "$RECOVERY_MANIFEST" || {
    recovery_error 'approval signature is missing, untrusted, or invalid'
    return 1
  }
  (( not_after - not_before <= RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS \
      && now - not_before <= RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS )) || {
    recovery_error 'approval exceeds the manifest policy maximum age'
    return 1
  }
}

# S/T semantic policy shared by rejoin admission and the checkpoint export
# gate: snapshot height above H, trust height/hash distinct from the
# snapshot, S+1/S+2 light-block coverage, and an unexpired trust window.
# Binding (run/host/manifest/attempt) is each caller's own concern.
recovery_validate_checkpoint_semantics() {
  local checkpoint="$1" source_height now expiry
  source_height="$(jq -er '.chain.source_height' "$RECOVERY_MANIFEST")" || return 1
  jq -e --argjson source_height "$source_height" '
    (.checkpoint.snapshot_height | type == "number" and floor == .)
    and .checkpoint.snapshot_height > $source_height
    and (.checkpoint.trust_height | type == "number" and floor == .)
    and .checkpoint.trust_height == .checkpoint.snapshot_height
    and (.checkpoint.trust_block_hash | test("^[A-Fa-f0-9]{64}$"))
    and (.checkpoint.snapshot_hash | test("^[A-Fa-f0-9]{64}$"))
    and ((.checkpoint.trust_block_hash | ascii_downcase) != (.checkpoint.snapshot_hash | ascii_downcase))
    and ([.checkpoint.supporting_light_blocks[].height] | sort)
      == [(.checkpoint.snapshot_height), (.checkpoint.snapshot_height + 1), (.checkpoint.snapshot_height + 2)]
  ' "$checkpoint" >/dev/null || {
    recovery_error 'checkpoint does not prove the default S/T and S+1/S+2 policy'
    return 1
  }
  # E1: host retention settings must not let the snapshot or trust-window
  # blocks be pruned before this checkpoint's own trust window expires.
  jq -e '
    (.checkpoint.expires_at | fromdateiso8601) as $expiry
    | (.checkpoint.snapshot_available_until | fromdateiso8601) >= $expiry
    and all(.checkpoint.supporting_light_blocks[]; (.available_until | fromdateiso8601) >= $expiry)
  ' "$checkpoint" >/dev/null || {
    recovery_error 'host retention settings could prune the snapshot or trust blocks before the checkpoint expires'
    return 1
  }
  expiry="$(jq -er '.checkpoint.expires_at' "$checkpoint")" || return 1
  expiry="$(recovery_epoch "$expiry")" || return 1
  now="$(date -u +%s)"
  (( expiry > now )) || {
    recovery_error 'checkpoint trust window has expired'
    return 1
  }
}

recovery_validate_checkpoint() {
  local checkpoint="$1" transition_host runtime_sha
  recovery_require_private_file "$checkpoint" || return 1
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$checkpoint" || return 1
  transition_host="$(jq -er '.transition.host' "$RECOVERY_MANIFEST")" || return 1
  runtime_sha="$(jq -er '.runtime.binary_sha256' "$RECOVERY_MANIFEST")" || return 1
  jq -e --arg run "$RECOVERY_RUN_ID" --arg manifest "$RECOVERY_MANIFEST_SHA256" --arg host "$transition_host" \
    --arg runtime "$runtime_sha" '
    .receipt_type == "checkpoint" and .run_id == $run
    and .manifest_sha256 == $manifest and .host == $host
    and .phase == "checkpoint" and .verdict == "PASS"
    and .checkpoint.manifest_sha256 == $manifest
    and .checkpoint.runtime_sha256 == $runtime
  ' "$checkpoint" >/dev/null || {
    recovery_error 'checkpoint is invalid or foreign'
    return 1
  }
  recovery_validate_checkpoint_semantics "$checkpoint"
}

# E1: the first returning host relies on a single trust source; require
# that risk explicitly accepted in the manifest's lab/review trail or the approval.
recovery_validate_single_source_acceptance() {
  local manifest="$1" approval="$2" host="$3" first_host
  first_host="$(jq -er '.hosts.return_order[0]' "$manifest")" || return 1
  [[ "$host" == "$first_host" ]] || return 0
  jq -e '(.trust.lab_qualification_receipts | length) > 0 and (.trust.review_receipts | length) > 0' \
    "$manifest" >/dev/null && return 0
  jq -e '.approval.signed_payload.single_source_risk_accepted == true' "$approval" >/dev/null || {
    recovery_error 'single-transition-source risk must be explicitly accepted in the approval or the manifest lab/review trail'
    return 1
  }
}

# E2: cross-checks a PASS rejoin handler's reported evidence against the
# checkpoint it was admitted with (restored height, common hash, fork marker).
recovery_validate_rejoin_state_sync_evidence() {
  local details="$1" checkpoint_sha trust_height
  checkpoint_sha="$(recovery_sha256 "$RECOVERY_CHECKPOINT")" || return 1
  trust_height="$(jq -er '.checkpoint.trust_height' "$RECOVERY_CHECKPOINT")" || return 1
  jq -e --arg checkpoint_sha "$checkpoint_sha" '.state_sync.checkpoint_receipt_sha256 == $checkpoint_sha' \
    <<<"$details" >/dev/null || {
    recovery_error 'rejoin evidence is not bound to the admitted checkpoint'
    return 1
  }
  jq -e --argjson trust_height "$trust_height" '.state_sync.restored_snapshot_height >= $trust_height' \
    <<<"$details" >/dev/null || {
    recovery_error 'restored snapshot height is below the checkpoint trust height'
    return 1
  }
  jq -e '.state_sync.fork_replacement_marker_found == false' <<<"$details" >/dev/null || {
    recovery_error 'returning host shows a testnet fork validator-set replacement marker'
    return 1
  }
  local common_height common_hash light_block_hash
  common_height="$(jq -er '.state_sync.common_height' <<<"$details")" || return 1
  common_hash="$(jq -er '.state_sync.common_block_hash | ascii_downcase' <<<"$details")" || return 1
  light_block_hash="$(jq -er --argjson height "$common_height" \
    '[.checkpoint.supporting_light_blocks[] | select(.height == $height)][0].block_hash // empty | ascii_downcase' \
    "$RECOVERY_CHECKPOINT")" || return 1
  [[ -n "$light_block_hash" && "$light_block_hash" == "$common_hash" ]] || {
    recovery_error 'rejoin common-height block hash does not match the transition host checkpoint evidence'
    return 1
  }
}

# E2: gates resume --step signers on local state, at or after retirement
# execution height, already showing every retired identity blocked.
recovery_validate_resume_signers_evidence() {
  local details="$1" transition_host retire_receipt execution_height local_height
  transition_host="$(jq -er '.transition.host' "$RECOVERY_MANIFEST")" || return 1
  retire_receipt="$(recovery_latest_receipt "$transition_host" retire '')" || {
    recovery_error 'no retire receipt is available to bound resume signers evidence'
    return 1
  }
  recovery_validate_phase_receipt_binding "$retire_receipt" "$transition_host" retire "$RECOVERY_MANIFEST_SHA256" '' || return 1
  execution_height="$(jq -er '.details.retirement.execution_height' "$retire_receipt")" || return 1
  local_height="$(jq -er '.resume.local_state_height' <<<"$details")" || return 1
  (( local_height >= execution_height )) || {
    recovery_error 'resume signers local state height precedes the retirement execution height'
    return 1
  }
  jq -e --slurpfile manifest "$RECOVERY_MANIFEST" '
    ($manifest[0].retirement.retired_identities
      | map([.participant_address, .account_address, .valoper_address] + (.delegated_or_warm_addresses // []))
      | flatten) as $required
    | (.resume.blocked_participant_addresses) as $blocked
    | ($required | length) > 0
    and all($required[]; . as $addr | $blocked | index($addr) != null)
  ' <<<"$details" >/dev/null || {
    recovery_error 'blocked_participant_addresses does not cover every retired identity'
    return 1
  }
}

recovery_register_handler() {
  local phase="$1" handler="$2"
  recovery_is_phase "$phase" || { recovery_error "cannot register unknown phase: $phase"; return 1; }
  [[ "$handler" =~ ^recovery_[a-z0-9_]+$ ]] || { recovery_error 'unsafe recovery handler name'; return 1; }
  declare -F "$handler" >/dev/null || { recovery_error "recovery handler is undefined: $handler"; return 1; }
  RECOVERY_REGISTERED_HANDLERS["$phase"]="$handler"
}

# E3: qualification records, one per (selector, handler), each OpenSSH-signed
# over its own canonical JSON -- same shape as approvals, a separate trust list.
recovery_qualification_file() { printf '%s\n' "${RECOVERY_QUALIFICATION_FILE:-$RECOVERY_ROOT/recovery/qualification.json}"; }
recovery_qualification_signers_file() { printf '%s\n' "${RECOVERY_QUALIFICATION_SIGNERS_FILE:-$RECOVERY_ROOT/recovery/qualification-signers.json}"; }

# Looks up the unique qualification record for this selector/handler, checks
# its code hash against the live function and its signature against the
# repository's own signer list, and sets RECOVERY_QUALIFICATION_MODE on
# success. A handler's "code" is its live `declare -f` body: this covers
# both a real script-defined handler and a test's inline fixture function
# without needing a second, separately-hashed artifact on disk.
recovery_load_qualification() {
  local selector="$1" handler="$2" file signers count record code_sha mode key_id public_key payload sig allowed
  RECOVERY_QUALIFICATION_MODE=''
  file="$(recovery_qualification_file)"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  jq -e 'type == "array"' "$file" >/dev/null 2>&1 || return 1
  count="$(jq --arg s "$selector" --arg h "$handler" '[.[] | select(.selector == $s and .handler == $h)] | length' "$file")" || return 1
  [[ "$count" == 1 ]] || return 1
  record="$(jq -c --arg s "$selector" --arg h "$handler" '[.[] | select(.selector == $s and .handler == $h)][0]' "$file")" || return 1
  code_sha="$(declare -f "$handler" | sha256sum | awk '{print tolower($1)}')" || return 1
  [[ "$(jq -r '.handler_code_sha256' <<<"$record")" == "$code_sha" ]] || {
    recovery_error 'qualification record code hash does not match the live handler'
    return 1
  }
  mode="$(jq -r '.mode' <<<"$record")"
  [[ "$mode" == rehearsal || "$mode" == supervised_live ]] || { recovery_error 'qualification record has an unknown mode'; return 1; }
  key_id="$(jq -r '.key_id' <<<"$record")"
  signers="$(recovery_qualification_signers_file)"
  [[ -f "$signers" && ! -L "$signers" ]] || return 1
  jq -e 'type == "array"' "$signers" >/dev/null 2>&1 || return 1
  public_key="$(jq -r --arg k "$key_id" '[.[] | select(.key_id == $k)][0].public_key // empty' "$signers")" || return 1
  [[ -n "$public_key" ]] || { recovery_error 'qualification record signer is not in the repository signer list'; return 1; }
  payload="$(mktemp)"; chmod 600 "$payload"
  jq -cS 'del(.signature)' <<<"$record" >"$payload"
  sig="$(jq -r '.signature' <<<"$record")"
  allowed="$(mktemp)"; chmod 600 "$allowed"
  printf '%s %s\n' "$key_id" "$public_key" >"$allowed"
  printf '%s\n' "$sig" >"$payload.sig"
  if ! ssh-keygen -Y verify -f "$allowed" -I "$key_id" -n gdc-network-recovery-qualification-v1 -s "$payload.sig" <"$payload" >/dev/null 2>&1; then
    rm -f "$payload" "$payload.sig" "$allowed"
    recovery_error 'qualification record signature verification failed'
    return 1
  fi
  rm -f "$payload" "$payload.sig" "$allowed"
  RECOVERY_QUALIFICATION_MODE="$mode"
}

# E3: reuses test-network-recovery-rehearsal.sh's isolated-lab authority
# (same env gate, same signed-approval path) -- one reviewed mechanism only.
recovery_validate_lab_authorization() {
  [[ "${GDC_RECOVERY_REHEARSAL_AUTHORIZED:-}" == true ]] || {
    recovery_error 'lab execution requires GDC_RECOVERY_REHEARSAL_AUTHORIZED=true'
    return 1
  }
  [[ "${GDC_RECOVERY_REHEARSAL_SCOPE:-}" == isolated-lab ]] || {
    recovery_error 'lab execution requires GDC_RECOVERY_REHEARSAL_SCOPE=isolated-lab'
    return 1
  }
  local approval="${GDC_RECOVERY_LAB_APPROVAL:-}" not_before not_after now
  recovery_require_private_file "$approval" || { recovery_error 'lab approval file is missing or not private'; return 1; }
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$approval" || return 1
  jq -e --arg run "$RECOVERY_RUN_ID" --arg host "$RECOVERY_HOST" --arg manifest "$RECOVERY_MANIFEST_SHA256" '
    .receipt_type == "approval"
    and .approval.signed_payload.namespace == "gdc-network-recovery-v1"
    and .approval.signed_payload.action == "lab_execution"
    and .approval.signed_payload.subject_kind == "final_manifest"
    and .approval.signed_payload.subject_sha256 == $manifest
    and .approval.signed_payload.run_id == $run
    and .approval.signed_payload.host == $host
  ' "$approval" >/dev/null || {
    recovery_error 'lab approval is not bound to this run/host/manifest'
    return 1
  }
  not_before="$(jq -er '.approval.signed_payload.not_before' "$approval")" || return 1
  not_after="$(jq -er '.approval.signed_payload.expires_at' "$approval")" || return 1
  not_before="$(recovery_epoch "$not_before")" || return 1
  not_after="$(recovery_epoch "$not_after")" || return 1
  now="$(date -u +%s)"
  (( now >= not_before && now <= not_after )) || { recovery_error 'lab approval is not currently valid'; return 1; }
  recovery_verify_approval_signature "$approval" "$RECOVERY_MANIFEST" || {
    recovery_error 'lab approval signature or manifest policy verification failed'
    return 1
  }
}

# E3: a qualified handler runs anywhere (subject to supervised_live);
# an unqualified one runs only under an explicit isolated-lab scope.
recovery_authorize_handler_execution() {
  local selector="$1" handler="$2" scope
  scope="$(jq -er '.execution.scope' "$RECOVERY_MANIFEST")" || return 1
  if recovery_load_qualification "$selector" "$handler"; then
    if [[ "$RECOVERY_QUALIFICATION_MODE" == supervised_live ]]; then
      case "$selector" in
        resume_poc|resume_handoff) ;;
        *) recovery_error 'supervised_live qualification is not permitted for this phase/step'; return 1 ;;
      esac
      jq -e --arg selector "$selector" '.execution.supervised_live_allowed_selectors | index($selector) != null' \
        "$RECOVERY_MANIFEST" >/dev/null || {
        recovery_error 'manifest does not list this step as approved for supervised_live'
        return 1
      }
    fi
    return 0
  fi
  [[ "$scope" == isolated_lab ]] || { recovery_error 'handler is not qualified for combat execution'; return 1; }
  jq -e --arg host "$RECOVERY_HOST" '.execution.lab_hosts | index($host) != null' "$RECOVERY_MANIFEST" >/dev/null || {
    recovery_error 'host is outside the manifest lab host list'
    return 1
  }
  recovery_validate_lab_authorization
}

recovery_next_attempt() {
  local phase_root="$1" number=1 candidate directory entry max=0 count=0 receipt selector
  recovery_safe_directory "$phase_root" create || {
    recovery_error "unsafe recovery attempt path: $phase_root"
    return 1
  }
  RECOVERY_PREVIOUS_ATTEMPT_RECEIPT_SHA256=''
  RECOVERY_PRIOR_ATTEMPT_INCOMPLETE=false
  for directory in "$phase_root"/attempt-*; do
    [[ -d "$directory" && ! -L "$directory" ]] || continue
    entry="$(basename "$directory")"; entry="${entry#attempt-}"
    [[ "$entry" =~ ^[1-9][0-9]*$ ]] || { recovery_error "unsafe attempt directory in $phase_root"; return 1; }
    ((count += 1)); (( entry > max )) && max="$entry"
  done
  (( count == max )) || { recovery_error "recovery attempt sequence contains a gap in $phase_root"; return 1; }
  if (( max > 0 )); then
    receipt="$phase_root/attempt-$max/receipt.json"
    if [[ -f "$receipt" && ! -L "$receipt" ]]; then
      RECOVERY_PREVIOUS_ATTEMPT_RECEIPT_SHA256="$(recovery_sha256 "$receipt")"
    else
      RECOVERY_PRIOR_ATTEMPT_INCOMPLETE=true
    fi
  fi
  number=$((max + 1))
  (( number <= 9999 )) || { recovery_error 'recovery attempt namespace is exhausted'; return 1; }
  candidate="$phase_root/attempt-$number"
  mkdir -m 0700 "$candidate" || { recovery_error 'recovery attempt allocation raced with another invocation'; return 1; }
  RECOVERY_ATTEMPT_NUMBER="$number"
  RECOVERY_ATTEMPT_DIR="$candidate"
  selector="$(recovery_selector)"
  RECOVERY_ATTEMPT_ID="attempt-$number-$(printf '%s' "$RECOVERY_RUN_ID:$RECOVERY_HOST:$selector" | sha256sum | awk '{print substr($1,1,16)}')"
  export RECOVERY_ATTEMPT_NUMBER RECOVERY_ATTEMPT_DIR RECOVERY_ATTEMPT_ID
  export RECOVERY_PREVIOUS_ATTEMPT_RECEIPT_SHA256 RECOVERY_PRIOR_ATTEMPT_INCOMPLETE
}

recovery_write_once() {
  local target="$1" source="$2"
  [[ ! -e "$target" && ! -L "$target" && -f "$source" ]] || return 1
  local temporary
  temporary="$(mktemp "$(dirname "$target")/.write-once.XXXXXX")"
  chmod 600 "$temporary"
  cp "$source" "$temporary"
  sync -f "$temporary" 2>/dev/null || sync "$temporary" 2>/dev/null || true
  chmod 400 "$temporary"
  # ln fails on an existing target, where mv would replace it.
  if ! ln "$temporary" "$target" 2>/dev/null; then
    rm -f "$temporary"
    return 1
  fi
  rm -f "$temporary"
}

# Evidence is shared across Hosts. Walk each existing component instead of
# trusting a final-path check, so a pre-existing symlink cannot redirect a
# lookup or a write beneath the controller/run root. This is a pre-access
# safeguard; shell path operations cannot eliminate same-user TOCTOU races.
recovery_safe_directory() {
  local path="$1" mode="${2:-read}" relative current='' component
  local -a components=()
  [[ "$mode" == read || "$mode" == create ]] || return 1
  [[ "$path" == /* && "$path" != / && "$path" != */../* && "$path" != */./* ]] || return 1
  relative="${path#/}"
  IFS=/ read -r -a components <<<"$relative"
  for component in "${components[@]}"; do
    [[ "$component" =~ ^[A-Za-z0-9._@+-]+$ ]] || return 1
    current+="/$component"
    [[ ! -L "$current" ]] || {
      recovery_error "symlink component is forbidden in recovery evidence path: $current"
      return 1
    }
    if [[ -e "$current" ]]; then
      [[ -d "$current" ]] || return 1
    elif [[ "$mode" == create ]]; then
      mkdir -m 0700 "$current" || return 1
    else
      # No later component can exist below a missing directory. The existing
      # prefix has been checked and the caller can safely treat this as absent.
      return 0
    fi
  done
  [[ "$(realpath "$path" 2>/dev/null)" == "$path" ]]
}

# Each approval_id and nonce is consumed at most once per run.
recovery_approval_consumption_dir() {
  printf '%s/runs/%s/recovery/approval-consumption\n' "$(recovery_evidence_root)" "$RECOVERY_RUN_ID"
}

# Recovery receipts describe one controller-coordinated run, whereas GDC_HOME
# contains the selected Host's private runtime state. Launchers provide the
# original controller root; direct library callers retain the historical
# single-home layout by falling back to GDC_HOME.
recovery_evidence_root() {
  printf '%s\n' "${GDC_RECOVERY_ROOT:-$GDC_HOME}"
}

# E4: one random per-machine identifier for the single operator machine that
# runs every phase over SSH (gdc.sh binds this root to $GDC_DATA_ROOT).
recovery_controller_id_path() {
  printf '%s/recovery-controller-id\n' "$(recovery_evidence_root)"
}

# Idempotent: only `inspect` calls this, and only the first inspect on a
# machine actually creates the file. Mode 0600 (not recovery_write_once's
# 0400): this is a re-readable machine identifier, not a sealed receipt.
recovery_ensure_controller_id() {
  local path="$1" temporary
  [[ -e "$path" || -L "$path" ]] && return 0
  temporary="$(mktemp "$(dirname "$path")/.controller-id.XXXXXX")" || return 1
  head -c 32 /dev/urandom | sha256sum | awk '{print $1}' >"$temporary"
  chmod 600 "$temporary"
  if ! ln "$temporary" "$path" 2>/dev/null; then
    rm -f "$temporary"
    [[ -e "$path" ]] || return 1
  else
    rm -f "$temporary"
  fi
}

# Read-only: later phases must never silently mint a new identity for a
# machine that never ran inspect.
recovery_controller_sha256() {
  recovery_require_private_file "$(recovery_controller_id_path)" || return 1
  recovery_sha256 "$(recovery_controller_id_path)"
}

recovery_validate_controller_binding() {
  local manifest="$1" expected local_sha
  expected="$(jq -er '.coordinator_sha256' "$manifest")" || return 1
  local_sha="$(recovery_controller_sha256)" || return 1
  [[ "$local_sha" == "$expected" ]] || {
    recovery_error 'controller identity does not match the coordinator machine bound in the manifest'
    return 1
  }
}

recovery_approval_already_consumed() {
  local approval_id="$1" nonce="$2" dir
  dir="$(recovery_approval_consumption_dir)"
  # An unsafe shared evidence path is equivalent to a consumed approval:
  # refuse before a potential redirected read.
  recovery_safe_directory "$dir" read || return 0
  [[ -e "$dir/approval-id.$approval_id" || -e "$dir/nonce.$nonce" ]]
}

recovery_consume_approval() {
  local approval_id="${RECOVERY_PENDING_APPROVAL_ID:-}" nonce="${RECOVERY_PENDING_APPROVAL_NONCE:-}" dir marker
  [[ -n "$approval_id" && -n "$nonce" ]] || return 0
  dir="$(recovery_approval_consumption_dir)"
  recovery_safe_directory "$dir" create || {
    recovery_error 'approval consumption path is unsafe'
    return 1
  }
  marker="$(mktemp)"; chmod 600 "$marker"; printf '%s\n' "${RECOVERY_ATTEMPT_ID:-}" >"$marker"
  if ! recovery_write_once "$dir/approval-id.$approval_id" "$marker"; then
    rm -f "$marker"
    recovery_error 'approval was already consumed in this run'
    return 1
  fi
  if ! recovery_write_once "$dir/nonce.$nonce" "$marker"; then
    rm -f "$marker"
    recovery_error 'approval nonce was already consumed in this run'
    return 1
  fi
  rm -f "$marker"
}

recovery_record_command() {
  local output="$RECOVERY_ATTEMPT_DIR/command.json" arg redact=false
  local -a rendered=()
  for arg in "$@"; do
    if [[ "$redact" == true ]]; then rendered+=("<redacted>"); redact=false; continue; fi
    case "$arg" in
      --*key|--*token|--*password|--*secret|--*mnemonic|--*credential) rendered+=("$arg"); redact=true ;;
      --*key=*|--*token=*|--*password=*|--*secret=*|--*mnemonic=*|--*credential=*) rendered+=("${arg%%=*}=<redacted>") ;;
      *) rendered+=("$arg") ;;
    esac
  done
  jq -cn --args '$ARGS.positional' -- "gdc" "network" "recover" "$RECOVERY_PHASE" "${rendered[@]}" >"$output"
  chmod 600 "$output"
}

recovery_selector() {
  case "$RECOVERY_PHASE" in
    resume) printf 'resume_%s\n' "$RECOVERY_STEP" ;;
    verify) printf 'verify_%s\n' "$RECOVERY_SCOPE" ;;
    *) printf '%s\n' "$RECOVERY_PHASE" ;;
  esac
}

recovery_phase_storage_path() {
  local phase="$1" qualifier="${2:-}"
  case "$phase" in
    resume)
      [[ "$qualifier" =~ ^(signers|poc|handoff)$ ]] || return 1
      printf 'resume/%s\n' "$qualifier"
      ;;
    verify)
      [[ "$qualifier" =~ ^(consensus|epochs|service)$ ]] || return 1
      printf 'verify/%s\n' "$qualifier"
      ;;
    *)
      recovery_is_phase "$phase" && [[ -z "$qualifier" ]] || return 1
      printf '%s\n' "$phase"
      ;;
  esac
}

recovery_receipt_relative_path() {
  local path="$1" root
  root="$(recovery_evidence_root)/runs/$RECOVERY_RUN_ID"
  [[ "$path" == "$root/"* ]] || return 1
  printf '%s\n' "${path#"$root/"}"
}

recovery_latest_receipt() {
  local host="$1" phase="$2" qualifier="${3:-}" phase_path phase_root receipt directory number latest='' latest_number=0 max_directory=0
  phase_path="$(recovery_phase_storage_path "$phase" "$qualifier")" || return 1
  phase_root="$(recovery_evidence_root)/runs/$RECOVERY_RUN_ID/recovery/$host/$phase_path"
  recovery_safe_directory "$phase_root" read || return 1
  [[ -d "$phase_root" ]] || return 1
  for directory in "$phase_root"/attempt-*; do
    [[ -d "$directory" && ! -L "$directory" ]] || continue
    number="${directory##*/attempt-}"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
    (( number > max_directory )) && max_directory="$number"
  done
  for receipt in "$phase_root"/attempt-*/receipt.json; do
    [[ -f "$receipt" && ! -L "$receipt" ]] || continue
    directory="$(basename "$(dirname "$receipt")")"
    number="${directory#attempt-}"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    if (( number > latest_number )); then
      latest="$receipt"
      latest_number="$number"
    fi
  done
  [[ -n "$latest" && "$latest_number" == "$max_directory" ]] || return 1
  printf '%s\n' "$latest"
}

recovery_validate_phase_receipt_binding() {
  local receipt="$1" host="$2" phase="$3" manifest_hash="$4" qualifier="${5:-}" admitted_cases_json='[]'
  recovery_require_private_file "$receipt" || return 1
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt" || return 1
  # C1: a retire predecessor's admitted first-boundary case is checked
  # against the manifest that is about to admit rejoin/resume poc, not the
  # retire attempt's own (already-superseded) claim.
  if [[ "$phase" == retire && -n "${RECOVERY_MANIFEST:-}" && -f "$RECOVERY_MANIFEST" ]]; then
    admitted_cases_json="$(jq -c '.first_boundary_policy.admitted_cases // []' "$RECOVERY_MANIFEST" 2>/dev/null)" || admitted_cases_json='[]'
  fi
  jq -e --arg run "$RECOVERY_RUN_ID" --arg host "$host" --arg phase "$phase" --arg manifest "$manifest_hash" --arg qualifier "$qualifier" \
    --argjson admitted_cases "$admitted_cases_json" '
    (.receipt_type == "phase" or .receipt_type == "verdict") and .run_id == $run and .host == $host
    and .phase == $phase
    and (if $manifest == "" then .manifest_sha256 == null else .manifest_sha256 == $manifest end)
    and (if $phase == "resume" then .step == $qualifier
         elif $phase == "verify" then .scope == $qualifier
         else $qualifier == "" end)
    and (if $phase == "inspect" then
           .verdict == "OBSERVED" and .exit_status == 0
           and .command.selector == "inspect"
           and .details.state == "INSPECTED"
           and (.details.inspection | type == "object")
           and .details.inspection.archive_coverage_verified == true
           and (.details.inspection.public_bindings | type == "array" and length > 0)
           and .terminal.evidence_complete == true
         elif $phase == "retire" then
           # C1: RETIRED unlocks rejoin/poc only with a qualified boundary
           # case, the transition key confirmed still active, every retired
           # identity actually blocked, and the minimum exclusion coverage.
           .verdict == "PASS" and .exit_status == 0
           and (.details.retirement.boundary_case | IN("A", "B"))
           and (.details.retirement.boundary_case == "A" or ($admitted_cases | index("B")) != null)
           and .details.retirement.transition_key_retained == true
           and .details.retirement.only_approved_parameter_changed == true
           and .details.retirement.retired_addresses_in_blocklist == true
           and .details.retirement.future_exclusion_verified == true
           and ((["poc_submission", "preserved", "fallback", "delegated"] - (.details.retirement.excluded_paths // [])) == [])
         elif $phase == "resume" and $qualifier == "poc" then
           # C2: resume handoff unlocks only once poc evidence, at the
           # effective height, already shows the temporary key excluded and
           # the remaining signers strictly above two-thirds power.
           .verdict == "PASS" and .exit_status == 0
           and .details.resume.temporary_key_excluded == true
           and .details.resume.power.strictly_over_two_thirds == true
         else
           .verdict == "PASS" and .exit_status == 0
         end)
  ' "$receipt" >/dev/null
}

recovery_require_predecessor() {
  local phase="$1" host="${2:-$RECOVERY_HOST}" manifest_hash="${3-$RECOVERY_MANIFEST_SHA256}" qualifier="${4:-}" receipt
  local label="$phase"
  [[ -z "$qualifier" ]] || label="$phase/$qualifier"
  receipt="$(recovery_latest_receipt "$host" "$phase" "$qualifier")" || {
    recovery_error "required predecessor receipt is absent: $host/$label"
    return 1
  }
  recovery_validate_phase_receipt_binding "$receipt" "$host" "$phase" "$manifest_hash" "$qualifier" || {
    recovery_error "required predecessor receipt is invalid or foreign: $host/$label"
    return 1
  }
  printf '%s\n' "$receipt"
}

recovery_append_predecessor() {
  local receipt="$1" sha entry
  sha="$(recovery_sha256 "$receipt")" || return 1
  entry="$(jq -cn --arg sha "$sha" --slurpfile receipt "$receipt" '
    $receipt[0] | {receipt_id,receipt_sha256:$sha,run_id,attempt_id,host,phase,verdict}
  ')" || return 1
  RECOVERY_PREDECESSOR_RECEIPTS="$(jq -cn \
    --argjson current "${RECOVERY_PREDECESSOR_RECEIPTS:-[]}" --argjson entry "$entry" '$current + [$entry]')"
}

recovery_add_required_predecessor() {
  local phase="$1" host="${2:-$RECOVERY_HOST}" manifest_hash="${3-$RECOVERY_MANIFEST_SHA256}" qualifier="${4:-}" receipt
  receipt="$(recovery_require_predecessor "$phase" "$host" "$manifest_hash" "$qualifier")" || return 1
  recovery_append_predecessor "$receipt"
}

recovery_collect_predecessors() {
  local selector transition_host='' draft_hash='' host previous_host='' return_index=''
  RECOVERY_PREDECESSOR_RECEIPTS='[]'
  selector="$(recovery_selector)"
  if [[ -n "${RECOVERY_MANIFEST:-}" ]]; then
    transition_host="$(jq -er '.transition.host' "$RECOVERY_MANIFEST")" || return 1
  fi
  case "$selector" in
    inspect|status) return 0 ;;
    prepare)
      recovery_add_required_predecessor inspect "$RECOVERY_HOST" ''
      ;;
    freeze)
      draft_hash="$(jq -er '.lifecycle.preparation_draft_sha256' "$RECOVERY_MANIFEST")" || return 1
      recovery_add_required_predecessor prepare "$RECOVERY_HOST" "$draft_hash"
      ;;
    stage)
      recovery_add_required_predecessor freeze
      ;;
    activate)
      while IFS= read -r host; do
        recovery_add_required_predecessor stage "$host" || return 1
      done < <(jq -er '.hosts.freeze_hosts[]' "$RECOVERY_MANIFEST")
      ;;
    checkpoint)
      recovery_add_required_predecessor activate "$transition_host"
      ;;
    retire)
      recovery_add_required_predecessor checkpoint "$transition_host"
      ;;
    rejoin)
      recovery_add_required_predecessor retire "$transition_host" || return 1
      return_index="$(jq -er --arg host "$RECOVERY_HOST" '.hosts.return_order | index($host)' "$RECOVERY_MANIFEST")" || return 1
      if (( return_index > 0 )); then
        previous_host="$(jq -er --argjson index "$((return_index - 1))" '.hosts.return_order[$index]' "$RECOVERY_MANIFEST")" || return 1
        recovery_add_required_predecessor rejoin "$previous_host"
      fi
      ;;
    resume_signers)
      recovery_add_required_predecessor rejoin
      ;;
    resume_poc)
      # FR-005: every returning host needs ready signers.
      while IFS= read -r host; do
        recovery_add_required_predecessor resume "$host" "$RECOVERY_MANIFEST_SHA256" signers || return 1
      done < <(jq -er '.hosts.return_order[]' "$RECOVERY_MANIFEST")
      ;;
    resume_handoff)
      while IFS= read -r host; do
        recovery_add_required_predecessor resume "$host" "$RECOVERY_MANIFEST_SHA256" poc || return 1
      done < <(jq -er '.hosts.return_order[]' "$RECOVERY_MANIFEST")
      ;;
    verify_consensus)
      recovery_add_required_predecessor resume "$transition_host" "$RECOVERY_MANIFEST_SHA256" handoff
      ;;
    verify_epochs)
      recovery_add_required_predecessor verify "$RECOVERY_HOST" "$RECOVERY_MANIFEST_SHA256" consensus
      ;;
    verify_service)
      recovery_add_required_predecessor verify "$RECOVERY_HOST" "$RECOVERY_MANIFEST_SHA256" epochs
      ;;
    abort) return 0 ;;
    *) recovery_error "unsupported recovery selector: $selector"; return 1 ;;
  esac
}

recovery_terminal_receipt() {
  local verdict="$1" exit_status="$2" mutation_state="$3" reason="$4" details="${5:-}"
  local finished receipt_tmp command_sha manifest_json previous_json selector manifest_binding step_json scope_json state terminal_state terminal_scope required_receipts prior_attempt_state
  local observed_hashes='[]' evidence='[]' checkpoint_sha checkpoint_path terminal_evidence_complete=false
  # FAIL was used by early handlers, but it is not a persisted schema verdict.
  # Normalize it at the only receipt-writing boundary and reject all unknown
  # values before constructing evidence.
  case "$verdict" in
    FAIL) verdict=FAILED ;;
    OBSERVED|PASS|REFUSED|BLOCKED|FAILED|INCONCLUSIVE) ;;
    *) recovery_error "unknown terminal verdict: $verdict"; return 1 ;;
  esac
  if [[ "$RECOVERY_PHASE" == checkpoint && "$verdict" == PASS ]]; then
    checkpoint_path="$RECOVERY_ATTEMPT_DIR/checkpoint.json"
    recovery_validate_checkpoint_artifact "$checkpoint_path" || {
      recovery_error 'checkpoint PASS requires a valid handler-produced checkpoint artifact'
      return 1
    }
    checkpoint_sha="$(recovery_sha256 "$checkpoint_path")" || return 1
    observed_hashes="$(jq -cn --arg sha "$checkpoint_sha" '[{kind:"checkpoint_artifact",sha256:$sha}]')"
    evidence="$(jq -cn --arg sha "$checkpoint_sha" --arg path "$checkpoint_path" \
      '[{kind:"checkpoint_artifact",sha256:$sha,location:$path,visibility:"raw_restricted"}]')"
  fi
  [[ -n "$details" ]] || details='{}'
  if [[ "$RECOVERY_PHASE" == inspect ]]; then
    observed_hashes="${RECOVERY_INSPECT_OBSERVED_HASHES:-[]}"
    [[ -n "$observed_hashes" ]] || observed_hashes='[]'
    # `${details:-{}}` mis-parses in bash (stray trailing brace); details is
    # already normalized to a non-empty string above, so use it directly.
    if jq -e '.inspection.evidence_complete == true' <<<"$details" >/dev/null 2>&1; then
      terminal_evidence_complete=true
    fi
  fi
  [[ ! -e "$RECOVERY_ATTEMPT_DIR/receipt.json" ]] || return 1
  finished="$(date -u +%FT%TZ)"
  command_sha="$(recovery_sha256 "$RECOVERY_ATTEMPT_DIR/command.json")"
  selector="$(recovery_selector)"
  if [[ -n "${RECOVERY_MANIFEST_SHA256:-}" ]]; then
    manifest_json="\"$RECOVERY_MANIFEST_SHA256\""
    [[ "$RECOVERY_PHASE" == prepare ]] && manifest_binding=preparation_draft || manifest_binding=final_manifest
  else
    manifest_json=null
    manifest_binding=none
  fi
  if [[ -n "${RECOVERY_PREVIOUS_ATTEMPT_RECEIPT_SHA256:-}" ]]; then
    previous_json="\"$RECOVERY_PREVIOUS_ATTEMPT_RECEIPT_SHA256\""
    prior_attempt_state=terminal
  else
    previous_json=null
    if (( RECOVERY_ATTEMPT_NUMBER == 1 )); then
      prior_attempt_state=none
    else
      prior_attempt_state=incomplete
    fi
  fi
  if [[ -n "${RECOVERY_STEP:-}" ]]; then step_json="\"$RECOVERY_STEP\""; else step_json=null; fi
  if [[ -n "${RECOVERY_SCOPE:-}" ]]; then scope_json="\"$RECOVERY_SCOPE\""; else scope_json=null; fi
  case "$verdict" in
    OBSERVED)
      # jq -e still prints `null` before failing on a missing field, so a
      # `||` fallback would concatenate onto that; use // instead.
      case "$RECOVERY_PHASE" in
        status) state="$(jq -r '.status.operator_state // "INCONCLUSIVE"' <<<"$details" 2>/dev/null)" ;;
        inspect) state="$(jq -r '.inspection.operator_state // "INCONCLUSIVE"' <<<"$details" 2>/dev/null)" ;;
        *) state=INCONCLUSIVE ;;
      esac
      [[ -n "$state" ]] || state=INCONCLUSIVE
      ;;
    REFUSED) state=REFUSED ;; BLOCKED) state=BLOCKED ;; FAILED) state=FAILED ;; INCONCLUSIVE) state=INCONCLUSIVE ;;
    PASS)
      case "$selector" in
        prepare) state=PREPARED ;; freeze) state=FROZEN ;; stage) state=STAGED ;; activate) state=SINGLETON_ACTIVE ;;
        checkpoint) state=CHECKPOINT_READY ;; retire) state=RETIRED ;; rejoin) state=REJOINED ;;
        resume_signers) state=SIGNERS_READY ;; resume_poc) state=POC_ACTIVE ;; resume_handoff) state=HANDOFF_COMPLETE ;;
        verify_*) state=VERIFIED ;; abort) state=ABORTED ;; *) state=INSPECTED ;;
      esac
      ;;
  esac
  case "$verdict" in
    PASS) terminal_state=PASS ;; REFUSED|FAILED) terminal_state=FAILED ;; BLOCKED) terminal_state=BLOCKED ;; *) terminal_state=INCONCLUSIVE ;;
  esac
  case "$RECOVERY_PHASE" in
    verify) terminal_scope="$RECOVERY_SCOPE" ;; retire) terminal_scope=retirement ;; *) terminal_scope=attempt ;;
  esac
  required_receipts="${RECOVERY_PREDECESSOR_RECEIPTS:-[]}"
  receipt_tmp="$(mktemp "$RECOVERY_ATTEMPT_DIR/.receipt.XXXXXX")"
  chmod 600 "$receipt_tmp"
  jq -n \
    --arg receipt_id "$RECOVERY_ATTEMPT_ID" --arg run "$RECOVERY_RUN_ID" --arg attempt "$RECOVERY_ATTEMPT_ID" \
    --argjson attempt_number "$RECOVERY_ATTEMPT_NUMBER" --argjson manifest "$manifest_json" \
    --arg manifest_binding "$manifest_binding" --argjson step "$step_json" --argjson scope "$scope_json" \
    --arg host "$RECOVERY_HOST" --arg phase "$RECOVERY_PHASE" --arg started "$RECOVERY_STARTED_AT" --arg finished "$finished" \
    --arg selector "$selector" --arg command_sha "$command_sha" --argjson exit_status "$exit_status" --arg verdict "$verdict" \
    --arg mutation "$mutation_state" --arg reason "$reason" --argjson predecessors "$required_receipts" \
    --argjson observed_hashes "$observed_hashes" --argjson evidence "$evidence" \
    --arg terminal_state "$terminal_state" --arg terminal_scope "$terminal_scope" --arg prior_attempt_state "$prior_attempt_state" \
    --argjson previous "$previous_json" --argjson phase_details "$details" --arg state "$state" --arg attempt_dir "$RECOVERY_ATTEMPT_DIR" \
    --argjson terminal_evidence_complete "$terminal_evidence_complete" '
      {schema_version:1,kind:"gdc-network-recovery-receipt",receipt_type:"verdict",
       receipt_id:$receipt_id,run_id:$run,attempt_id:$attempt,attempt_number:$attempt_number,
       sequence:1,manifest_binding_kind:$manifest_binding,manifest_sha256:$manifest,
       host:$host,phase:$phase,started_at:$started,finished_at:$finished,
       command:{selector:$selector,redacted:true,argv_sha256:$command_sha},exit_status:$exit_status,verdict:$verdict,
       mutation_state:$mutation,observed_hashes:$observed_hashes,evidence:$evidence,next_permitted_steps:[],
       predecessor_receipts:$predecessors,
       append_only:{immutable:true,attempt_directory:$attempt_dir,prior_attempt_state:$prior_attempt_state,raw_evidence_separate:true,sanitized_receipt:true},
       details:({state:$state,reason_code:$reason,message:$reason} + $phase_details),
       terminal:{scope:$terminal_scope,state:$terminal_state,reason_code:$reason,required_receipts:$predecessors,evidence_complete:$terminal_evidence_complete,incident_closure_authorized:false}}
      | if $step == null then . else . + {step:$step} end
      | if $scope == null then . else . + {scope:$scope} end
      | if $previous == null then . else . + {previous_attempt_receipt_sha256:$previous} end
    ' >"$receipt_tmp"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt_tmp" || {
    recovery_error 'terminal recovery receipt does not match its schema'
    rm -f "$receipt_tmp"
    return 70
  }
  mv "$receipt_tmp" "$RECOVERY_ATTEMPT_DIR/receipt.json"
  chmod 400 "$RECOVERY_ATTEMPT_DIR/receipt.json"
}

recovery_validate_checkpoint_artifact() {
  local source="${1:-$RECOVERY_ATTEMPT_DIR/checkpoint.json}" runtime_sha
  [[ -n "${RECOVERY_MANIFEST:-}" && -n "${RECOVERY_MANIFEST_SHA256:-}" ]] || {
    recovery_error 'checkpoint artifact validation requires an admitted manifest binding'
    return 1
  }
  runtime_sha="$(jq -er '.runtime.binary_sha256' "$RECOVERY_MANIFEST")" || return 1
  recovery_require_private_file "$source" || {
    recovery_error 'checkpoint requires a private checkpoint.json artifact from the handler'
    return 1
  }
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$source" || {
    recovery_error 'checkpoint artifact is not schema-valid'
    return 1
  }
  jq -e --arg run "$RECOVERY_RUN_ID" --arg host "$RECOVERY_HOST" --arg manifest "$RECOVERY_MANIFEST_SHA256" \
    --arg attempt "$RECOVERY_ATTEMPT_ID" --argjson attempt_number "$RECOVERY_ATTEMPT_NUMBER" \
    --arg attempt_dir "$RECOVERY_ATTEMPT_DIR" --arg runtime "$runtime_sha" '
    .receipt_type == "checkpoint" and .phase == "checkpoint"
    and .verdict == "PASS" and .exit_status == 0
    and .run_id == $run and .host == $host and .manifest_sha256 == $manifest
    and .attempt_id == $attempt and .attempt_number == $attempt_number
    and .append_only.attempt_directory == $attempt_dir
    and .checkpoint.manifest_sha256 == $manifest
    and .checkpoint.runtime_sha256 == $runtime
    and (.checkpoint | type == "object")
  ' "$source" >/dev/null || {
    recovery_error 'checkpoint artifact has a foreign or incomplete binding'
    return 1
  }
  recovery_validate_checkpoint_semantics "$source"
}

recovery_export_receipt() {
  local output="$RECOVERY_OUTPUT" target source="$RECOVERY_ATTEMPT_DIR/receipt.json"
  [[ -n "$output" ]] || return 0
  recovery_canonical_output_path "$output" || {
    recovery_error "output must be a new canonical persistent path: $output"
    return 1
  }
  if [[ "$RECOVERY_PHASE" == checkpoint ]]; then
    source="$RECOVERY_ATTEMPT_DIR/checkpoint.json"
    recovery_validate_checkpoint_artifact "$source" || return 1
  fi
  if [[ "$output" == *.json ]]; then
    target="$output"
  else
    mkdir -m 0700 "$output"
    target="$output/receipt.json"
  fi
  recovery_write_once "$target" "$source"
}

# Stage-1 fallback: controller-only metadata, no SSH. Used whenever a bounded
# host observation cannot be completed in full; never unlocks prepare.
recovery_local_controller_inspect() {
  local details='{}'
  jq -n --arg runbook_revision "$(runbook_revision)" \
    --arg launcher_sha256 "$(gdc_launcher_sha256)" \
    --arg incident "$RECOVERY_INCIDENT" --arg host "$RECOVERY_HOST" \
    --arg observation_scope local_controller_only \
    '{runbook_revision:$runbook_revision,gdc_launcher_sha256:$launcher_sha256,
      incident:$incident,host:$host,observation_scope:$observation_scope,
      network_observation_complete:false,signer_observation_complete:false}' \
    >"$RECOVERY_ATTEMPT_DIR/local-inspection.json"
  chmod 600 "$RECOVERY_ATTEMPT_DIR/local-inspection.json"
  recovery_terminal_receipt OBSERVED 0 none local_inspection_requires_bounded_host_evidence "$details"
}

# RECOVERY REMOTE COMMAND CATALOG BEGIN
# Fixed, read-only, bounded observation commands for `inspect` (HF-05 block
#1 / FR-005 5.3). This is the only place in the recovery implementation
# permitted to name ssh/docker/curl; the static side-effect guard in
# scripts/test-network-recovery-contract.sh enforces that boundary. Every
# command here is read-only: no compose up/down, no key material, no writes
# on the host. Parameters are restricted to the already-validated host alias
# and positive integer height/page, so no interpolated value can escape the
# remote command string.
recovery_remote_catalog_command() {
  local label="$1" host="$2" height="${3:-}" page="${4:-}" dir source_home tmkms_state
  [[ "$host" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] || return 2
  # shellcheck disable=SC2059 # the template is a fixed, reviewed constant
  dir="$(printf "$RECOVERY_REMOTE_COMPOSE_DIR_TEMPLATE" "$host")"
  # shellcheck disable=SC2059
  source_home="$(printf "$RECOVERY_REMOTE_SOURCE_HOME_TEMPLATE" "$host")"
  # shellcheck disable=SC2059
  tmkms_state="$(printf "$RECOVERY_REMOTE_TMKMS_STATE_TEMPLATE" "$host")"
  case "$label" in
    status)
      printf 'cd %s && docker compose exec -T node curl -fsS --max-time 5 http://127.0.0.1:26657/status\n' "$dir" ;;
    genesis_sha256)
      printf 'cd %s && docker compose exec -T node sh -c "curl -fsS --max-time 5 http://127.0.0.1:26657/genesis"\n' "$dir" ;;
    block)
      [[ "$height" =~ ^[1-9][0-9]*$ ]] || return 2
      printf 'cd %s && docker compose exec -T node curl -fsS --max-time 5 "http://127.0.0.1:26657/block?height=%s"\n' "$dir" "$height" ;;
    commit)
      [[ "$height" =~ ^[1-9][0-9]*$ ]] || return 2
      printf 'cd %s && docker compose exec -T node curl -fsS --max-time 5 "http://127.0.0.1:26657/commit?height=%s"\n' "$dir" "$height" ;;
    validators)
      [[ "$height" =~ ^[1-9][0-9]*$ && "$page" =~ ^[1-9][0-9]*$ ]] || return 2
      printf 'cd %s && docker compose exec -T node curl -fsS --max-time 5 "http://127.0.0.1:26657/validators?height=%s&page=%s&per_page=100"\n' "$dir" "$height" "$page" ;;
    image)
      printf 'cd %s && docker compose images --format json node\n' "$dir" ;;
    mounts)
      printf 'cd %s && docker inspect --format "{{json .Mounts}}" "$(docker compose ps -q node)"\n' "$dir" ;;
    restart_policy)
      printf 'cd %s && docker inspect --format "{{.HostConfig.RestartPolicy.Name}}" "$(docker compose ps -q node)"\n' "$dir" ;;
    binary_sha256)
      # E5: PID 1 is `sh ./init-docker.sh`, not the chain binary; resolve
      # inferenced's own path inside the container instead of hashing PID 1.
      printf 'cd %s && docker compose exec -T node sh -c "sha256sum \\"\\$(command -v inferenced)\\""\n' "$dir" ;;
    signer_config)
      # Only the public listen-address field; never the key file itself.
      printf 'grep -E "^priv_validator_laddr" %s/config/config.toml 2>/dev/null || true\n' "$source_home" ;;
    tmkms_presence)
      printf 'test -e %s && echo present || echo absent\n' "$tmkms_state" ;;
    *) return 2 ;;
  esac
}

# BatchMode + ConnectTimeout, plus a hard wall-clock cap per command, and a
# capped output size. Never touch `set -e`/`set +e` here: this function must
# return its real status to the caller, and toggling errexit inside a
# function that then returns nonzero re-arms it before the caller's own
# `rc=$?` runs, killing the whole script (bash's shared, non-scoped -e).
recovery_ssh_observe() {
  local host="$1" label="$2" outfile="$3" rc remote_cmd timeout_bin
  shift 3
  remote_cmd="$(recovery_remote_catalog_command "$label" "$host" "$@")" || return 2
  timeout_bin="$(command -v timeout || command -v gtimeout)" || {
    recovery_error 'bounded host observation requires GNU timeout/gtimeout on the operator machine'
    return 2
  }
  : >"$outfile"; chmod 600 "$outfile"
  if "$timeout_bin" -k 1 "$RECOVERY_SSH_COMMAND_TIMEOUT_SECONDS" \
       ssh -o BatchMode=yes -o ConnectTimeout="$RECOVERY_SSH_CONNECT_TIMEOUT_SECONDS" \
           -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new \
           "$host" -- "$remote_cmd" 2>/dev/null | head -c "$RECOVERY_SSH_MAX_OUTPUT_BYTES" >"$outfile"; then
    rc=0
  else
    rc="${PIPESTATUS[0]}"
  fi
  return "$rc"
}
# RECOVERY REMOTE COMMAND CATALOG END

# Records one bounded observation's time and source alongside its digest.
# `list_file` starts as "[]"; never stores the raw remote command or output.
recovery_inspect_append_observed() {
  local list_file="$1" kind="$2" file="$3" observed_at="$4" source="$5" height="${6:-}" sha entry tmp
  sha="$(recovery_sha256 "$file")" || return 1
  if [[ -n "$height" ]]; then
    entry="$(jq -cn --arg kind "$kind" --arg sha "$sha" --arg at "$observed_at" --arg src "$source" --argjson height "$height" \
      '{kind:$kind,sha256:$sha,height:$height,observed_at:$at,source:$src}')" || return 1
  else
    entry="$(jq -cn --arg kind "$kind" --arg sha "$sha" --arg at "$observed_at" --arg src "$source" \
      '{kind:$kind,sha256:$sha,observed_at:$at,source:$src}')" || return 1
  fi
  tmp="$(mktemp "$(dirname "$list_file")/.observed.XXXXXX")"
  jq -cn --argjson current "$(cat "$list_file")" --argjson entry "$entry" '$current + [$entry]' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$list_file"
}

# Fetches every page of /validators?height=$height, merging validator
# objects into $out_array (a JSON array file) and recording one observed_hash
# per page. Stops at the reported total or the page cap; any page failure or
# malformed response makes the whole set incomplete (fail closed).
recovery_inspect_paginate_validators() {
  local host="$1" height="$2" kind="$3" out_array="$4" list_file="$5" work="$6"
  local page=1 total merged collected page_file
  printf '[]\n' >"$out_array"
  while :; do
    page_file="$work/${kind}-page-$page.json"
    recovery_ssh_observe "$host" validators "$page_file" "$height" "$page" || return 1
    jq -e '(.result.validators | type == "array") and (.result.total | test("^[0-9]+$"))' "$page_file" >/dev/null 2>&1 || return 1
    recovery_inspect_append_observed "$list_file" "$kind" "$page_file" "$(date -u +%FT%TZ)" "ssh:$host:validators" "$height" || return 1
    total="$(jq -r '.result.total' "$page_file")" || return 1
    merged="$(jq -s '.[0] + .[1].result.validators' "$out_array" "$page_file")" || return 1
    printf '%s\n' "$merged" >"$out_array"
    collected="$(jq 'length' "$out_array")" || return 1
    (( collected >= total )) && break
    (( page < RECOVERY_INSPECT_MAX_VALIDATOR_PAGES )) || return 1
    page=$((page + 1))
  done
}

# Sums arbitrary-precision decimal voting-power strings; jq's doubles are not
# safe for on-chain power totals.
recovery_sum_power() {
  python3 -c '
import sys
total = 0
for line in sys.stdin:
    line = line.strip()
    if line:
        total += int(line)
print(total)
'
}

# Strict >2/3 threshold: matches the incident'"'"'s own arithmetic (135 total,
# 91 = floor(135*2/3)+1).
recovery_strict_required_power() {
  python3 -c 'import sys; t = int(sys.argv[1]); print(t * 2 // 3 + 1)' "$1"
}

# Attempts the complete bounded host observation. Every required probe uses
# an explicit `|| return 1`: bash's errexit is not relied on here, since it
# is silently suspended for the whole call chain once this runs as the
# condition of an `if` (a standard bash quirk, not a bug in this function).
# Populates $evidence_dir/summary.json and $evidence_dir/observed-hashes.json
# on success only; any failure leaves partial files that the caller ignores.
recovery_host_inspect_attempt() {
  local evidence_dir="$1" host="$RECOVERY_HOST" work list_file
  local chain_id height1 hash1 earliest height2 now
  local genesis_file app_hash commit_verified signers_file
  local archive_ok=false block_file
  local validators_h_file validators_h1_file validator_set_h_sha validator_set_h1_sha
  local total_power available_power required_power quorum_recoverable=false
  local higher_commit_found=false
  local image_file mounts_file restart_file binary_file runtime_sha image_digest mounts_sha restart_mechanism
  local laddr_file laddr tmkms_file tmkms_present=false signer_mode=unknown
  local started_at completed_at status1_file status2_file commit_file commit2_file controller_sha
  work="$evidence_dir"
  list_file="$evidence_dir/observed-hashes.json"
  printf '[]\n' >"$list_file"

  # E4: created on the very first inspect on this machine; every later phase
  # binds to this exact hash via manifest.coordinator_sha256.
  recovery_ensure_controller_id "$(recovery_controller_id_path)" || return 1
  controller_sha="$(recovery_controller_sha256)" || return 1

  started_at="$(date -u +%FT%TZ)"
  status1_file="$work/status-1.json"
  recovery_ssh_observe "$host" status "$status1_file" || return 1
  jq -e '.result.sync_info.latest_block_height | test("^[1-9][0-9]*$")' "$status1_file" >/dev/null 2>&1 || return 1
  recovery_inspect_append_observed "$list_file" chain_status "$status1_file" "$started_at" "ssh:$host:status" || return 1
  chain_id="$(jq -er '.result.node_info.network' "$status1_file")" || return 1
  height1="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$status1_file")" || return 1
  hash1="$(jq -er '.result.sync_info.latest_block_hash | ascii_downcase' "$status1_file")" || return 1
  earliest="$(jq -er '.result.sync_info.earliest_block_height | tonumber' "$status1_file")" || return 1

  sleep "$RECOVERY_INSPECT_REOBSERVE_DELAY_SECONDS" 2>/dev/null || true
  status2_file="$work/status-2.json"
  recovery_ssh_observe "$host" status "$status2_file" || return 1
  jq -e '.result.sync_info.latest_block_height | test("^[1-9][0-9]*$")' "$status2_file" >/dev/null 2>&1 || return 1
  recovery_inspect_append_observed "$list_file" chain_status_reobserve "$status2_file" "$(date -u +%FT%TZ)" "ssh:$host:status" || return 1
  height2="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$status2_file")" || return 1
  if (( height2 > height1 )); then
    commit2_file="$work/commit-2.json"
    recovery_ssh_observe "$host" commit "$commit2_file" "$height2" || return 1
    jq -e '.result.signed_header.header.height == ($h|tostring)
        and ([.result.signed_header.commit.signatures[]? | select(.block_id_flag == 2 and .signature != null)] | length) > 0' \
      --argjson h "$height2" "$commit2_file" >/dev/null 2>&1 || return 1
    recovery_inspect_append_observed "$list_file" commit_above_source "$commit2_file" "$(date -u +%FT%TZ)" "ssh:$host:commit" "$height2" || return 1
    higher_commit_found=true
  fi

  genesis_file="$work/genesis.json"
  recovery_ssh_observe "$host" genesis_sha256 "$genesis_file" || return 1
  jq -e '.result.genesis.chain_id == $c' --arg c "$chain_id" "$genesis_file" >/dev/null 2>&1 || return 1
  recovery_inspect_append_observed "$list_file" genesis "$genesis_file" "$(date -u +%FT%TZ)" "ssh:$host:genesis" || return 1

  commit_file="$work/commit-h.json"
  recovery_ssh_observe "$host" commit "$commit_file" "$height1" || return 1
  jq -e '.result.signed_header.header.height == ($h|tostring)' --argjson h "$height1" "$commit_file" >/dev/null 2>&1 || return 1
  app_hash="$(jq -er '.result.signed_header.header.app_hash | ascii_downcase' "$commit_file")" || return 1
  signers_file="$work/signers-h.json"
  jq -c '[.result.signed_header.commit.signatures[]? | select(.block_id_flag == 2 and .signature != null) | .validator_address]' \
    "$commit_file" >"$signers_file" || return 1
  commit_verified="$(jq -r 'length > 0' "$signers_file")" || return 1
  recovery_inspect_append_observed "$list_file" commit_h "$commit_file" "$(date -u +%FT%TZ)" "ssh:$host:commit" "$height1" || return 1

  if (( earliest == 1 )); then
    block_file="$work/block-1.json"
    recovery_ssh_observe "$host" block "$block_file" 1 || return 1
    jq -e '.result.block.header.height == "1"' "$block_file" >/dev/null 2>&1 || return 1
    recovery_inspect_append_observed "$list_file" archive_floor "$block_file" "$(date -u +%FT%TZ)" "ssh:$host:block" 1 || return 1
    archive_ok=true
  fi

  validators_h_file="$work/validators-h.json"
  recovery_inspect_paginate_validators "$host" "$height1" validators_h "$validators_h_file" "$list_file" "$work" || return 1
  validator_set_h_sha="$(jq -cS . "$validators_h_file" | sha256sum | awk '{print tolower($1)}')"

  validators_h1_file="$work/validators-h1.json"
  recovery_inspect_paginate_validators "$host" "$((height1 + 1))" validators_h_plus_1 "$validators_h1_file" "$list_file" "$work" || return 1
  validator_set_h1_sha="$(jq -cS . "$validators_h1_file" | sha256sum | awk '{print tolower($1)}')"

  total_power="$(jq -r '.[].voting_power' "$validators_h1_file" | recovery_sum_power)" || return 1
  available_power="$(jq -r --slurpfile signers "$signers_file" '
      ($signers[0] // []) as $s | .[] | select(.address as $a | $s | index($a)) | .voting_power
    ' "$validators_h1_file" | recovery_sum_power)" || return 1
  required_power="$(recovery_strict_required_power "$total_power")" || return 1
  [[ "$available_power" -ge "$required_power" ]] && quorum_recoverable=true

  image_file="$work/image.json"
  recovery_ssh_observe "$host" image "$image_file" || return 1
  recovery_inspect_append_observed "$list_file" runtime_image "$image_file" "$(date -u +%FT%TZ)" "ssh:$host:image" || return 1
  image_digest="$(recovery_sha256 "$image_file")" || return 1

  mounts_file="$work/mounts.json"
  recovery_ssh_observe "$host" mounts "$mounts_file" || return 1
  recovery_inspect_append_observed "$list_file" mounts "$mounts_file" "$(date -u +%FT%TZ)" "ssh:$host:mounts" || return 1
  mounts_sha="$(recovery_sha256 "$mounts_file")" || return 1

  restart_file="$work/restart.json"
  recovery_ssh_observe "$host" restart_policy "$restart_file" || return 1
  restart_mechanism="$(tr -d '[:space:]' <"$restart_file" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$restart_mechanism" ]] || restart_mechanism=none
  [[ "$restart_mechanism" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || return 1
  recovery_inspect_append_observed "$list_file" restart_mechanism "$restart_file" "$(date -u +%FT%TZ)" "ssh:$host:restart" || return 1

  binary_file="$work/binary.json"
  recovery_ssh_observe "$host" binary_sha256 "$binary_file" || return 1
  runtime_sha="$(awk '{print tolower($1); exit}' "$binary_file")" || return 1
  [[ "$runtime_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
  recovery_inspect_append_observed "$list_file" runtime_binary "$binary_file" "$(date -u +%FT%TZ)" "ssh:$host:binary" || return 1

  laddr_file="$work/laddr.json"
  recovery_ssh_observe "$host" signer_config "$laddr_file" || return 1
  laddr="$(sed -n 's/^priv_validator_laddr[[:space:]]*=[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$laddr_file" | head -1)"
  recovery_inspect_append_observed "$list_file" signer_config "$laddr_file" "$(date -u +%FT%TZ)" "ssh:$host:signer_config" || return 1

  tmkms_file="$work/tmkms.json"
  recovery_ssh_observe "$host" tmkms_presence "$tmkms_file" || return 1
  [[ "$(tr -d '[:space:]' <"$tmkms_file")" == present ]] && tmkms_present=true
  recovery_inspect_append_observed "$list_file" tmkms_presence "$tmkms_file" "$(date -u +%FT%TZ)" "ssh:$host:tmkms" || return 1
  if [[ "$tmkms_present" == true ]]; then signer_mode=tmkms
  elif [[ -n "$laddr" ]]; then signer_mode=local_file_pv
  fi
  [[ -n "$laddr" ]] || laddr=''
  [[ "$laddr" =~ ^(tcp://[A-Za-z0-9.:%-]+)?$ ]] || laddr=''

  completed_at="$(date -u +%FT%TZ)"
  now="$(date -u +%s)"
  local fresh=true entry entry_epoch
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    entry_epoch="$(recovery_epoch "$entry")" || return 1
    (( now - entry_epoch <= RECOVERY_INSPECT_MAX_EVIDENCE_AGE_SECONDS )) || fresh=false
  done < <(jq -r '.[].observed_at' "$list_file")

  local public_bindings validator_address='' validator_pubkey_sha
  validator_address="$(jq -r '.result.validator_info.address // empty | ascii_downcase' "$status1_file" 2>/dev/null || true)"
  if [[ -n "$validator_address" ]]; then
    validator_pubkey_sha="$(jq -r '.result.validator_info.pub_key.value // .result.validator_info.address' "$status1_file" \
      | sha256sum | awk '{print tolower($1)}')"
    public_bindings="$(jq -cn --arg id "$validator_address" --arg sha "$validator_pubkey_sha" \
      '[{binding_kind:"consensus_key",binding_id:$id,public_value_sha256:$sha}]')"
  else
    public_bindings='[]'
  fi
  public_bindings="$(jq -cn --argjson current "$public_bindings" --arg id "$host" --arg sha "$image_digest" \
    '$current + [{binding_kind:"compose_project",binding_id:$id,public_value_sha256:$sha}]')"

  local archive_json quorum_json evidence_complete=false
  archive_json="$archive_ok"
  quorum_json="$(jq -cn --argjson height "$((height1 + 1))" --arg total "$total_power" --arg available "$available_power" \
    --arg required "$required_power" --arg validator_set_sha "$validator_set_h1_sha" '
    {height:$height,total_power:$total,available_power:$available,strict_required_power:$required,
     strictly_over_two_thirds:(($available|tonumber) > (($total|tonumber) * 2 / 3)),validator_set_sha256:$validator_set_sha}
  ')"
  if [[ "$archive_ok" == true && $(jq 'length > 0' <<<"$public_bindings") == true && "$fresh" == true \
        && "$higher_commit_found" == false && "$quorum_recoverable" == false ]]; then
    evidence_complete=true
  fi

  jq -cn \
    --arg chain_id "$chain_id" --argjson observed_height "$height1" --arg app_hash "$app_hash" \
    --arg validator_set_h1_sha "$validator_set_h1_sha" --arg runtime_sha "$runtime_sha" \
    --argjson public_bindings "$public_bindings" --argjson archive_ok "$archive_json" \
    --arg genesis_sha "$(recovery_sha256 "$genesis_file")" --arg last_block_hash "$hash1" \
    --argjson commit_verified "$commit_verified" --arg validator_set_h_sha "$validator_set_h_sha" \
    --arg image_digest "$image_digest" --arg mounts_sha "$mounts_sha" --arg restart_mechanism "$restart_mechanism" \
    --arg signer_mode "$signer_mode" --arg laddr "$laddr" --argjson tmkms_present "$tmkms_present" \
    --argjson fresh "$fresh" --argjson higher_commit_found "$higher_commit_found" \
    --argjson quorum_recoverable "$quorum_recoverable" --argjson quorum_power "$quorum_json" \
    --arg started_at "$started_at" --arg completed_at "$completed_at" --argjson evidence_complete "$evidence_complete" \
    --arg controller_sha "$controller_sha" \
    '{chain_id:$chain_id,observed_height:$observed_height,source_application_hash:$app_hash,
      complete_validator_set_sha256:$validator_set_h1_sha,runtime_sha256:$runtime_sha,
      public_bindings:$public_bindings,archive_coverage_verified:$archive_ok,controller_sha256:$controller_sha,
      operator_state:"INSPECTED",evidence_complete:$evidence_complete,
      genesis_sha256:$genesis_sha,last_block_hash:$last_block_hash,commit_verified:$commit_verified,
      validator_set_h_sha256:$validator_set_h_sha,runtime_image_digest:$image_digest,mounts_sha256:$mounts_sha,
      restart_mechanism:$restart_mechanism,signer_mode:$signer_mode,priv_validator_laddr:$laddr,
      tmkms_present:$tmkms_present,evidence_fresh:$fresh,higher_commit_found:$higher_commit_found,
      quorum_recoverable:$quorum_recoverable,quorum_power:$quorum_power,
      observation_started_at:$started_at,observation_completed_at:$completed_at}' \
    >"$evidence_dir/summary.json" || return 1
}

# Full bounded SSH host inspect. Falls back to the stage-1 controller-only
# receipt whenever any required observation is missing, stale, or
# inconsistent; a stop condition (stale evidence, a confirmed commit above
# H, or a recoverable original quorum) is recorded as incomplete evidence
# rather than a hard error, matching FR-003's `inspect` contract.
recovery_host_inspect() {
  local evidence_dir="$RECOVERY_ATTEMPT_DIR/evidence" details reason
  recovery_safe_directory "$evidence_dir" create || {
    recovery_local_controller_inspect
    return
  }
  if recovery_host_inspect_attempt "$evidence_dir"; then
    local observed_hashes_json inspection_json
    observed_hashes_json="$(cat "$evidence_dir/observed-hashes.json")"
    inspection_json="$(cat "$evidence_dir/summary.json")"
    RECOVERY_INSPECT_OBSERVED_HASHES="$observed_hashes_json"
    if jq -e '.evidence_fresh == false' <<<"$inspection_json" >/dev/null; then
      reason=inspect_evidence_stale
    elif jq -e '.higher_commit_found == true' <<<"$inspection_json" >/dev/null; then
      reason=higher_commit_confirmed_above_source_height
    elif jq -e '.quorum_recoverable == true' <<<"$inspection_json" >/dev/null; then
      reason=original_quorum_recoverable
    elif jq -e '.evidence_complete == true' <<<"$inspection_json" >/dev/null; then
      reason=bounded_host_evidence_complete
    else
      reason=bounded_host_evidence_incomplete
    fi
    details="$(jq -cn --argjson inspection "$inspection_json" '{inspection:$inspection}')"
    recovery_terminal_receipt OBSERVED 0 none "$reason" "$details"
  else
    RECOVERY_INSPECT_OBSERVED_HASHES=''
    recovery_local_controller_inspect
  fi
}

recovery_local_inspect() {
  recovery_host_inspect
}

# Reads the singleton time/block budget from the manifest and the highest
# height any locally retained receipt has recorded so far; status never
# queries the chain itself (observation only, per FR-003).
recovery_singleton_budget() {
  local manifest="$1" host="$2" first_counted max_blocks deadline now
  local current_height consumed remaining_blocks remaining_seconds expired
  local item phase qualifier receipt height_candidate
  first_counted="$(jq -er '.singleton.first_counted_height' "$manifest")" || return 1
  max_blocks="$(jq -er '.singleton.singleton_max_blocks' "$manifest")" || return 1
  deadline="$(jq -er '.singleton.singleton_deadline_utc' "$manifest")" || return 1
  deadline="$(recovery_epoch "$deadline")" || return 1
  now="$(date -u +%s)"
  current_height="$first_counted"
  for item in activate rejoin resume:signers resume:poc resume:handoff verify:consensus verify:epochs verify:service; do
    phase="${item%%:*}"; if [[ "$item" == *:* ]]; then qualifier="${item#*:}"; else qualifier=''; fi
    receipt="$(recovery_latest_receipt "$host" "$phase" "$qualifier" 2>/dev/null || true)"
    [[ -n "$receipt" ]] || continue
    recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt" >/dev/null 2>&1 || continue
    height_candidate="$(jq -r '
      [(.details.activation.subsequent_commits // [])[-1].height, .details.activation.first_commit.height,
       .details.state_sync.common_height] | map(select(. != null)) | if length > 0 then max else empty end
    ' "$receipt" 2>/dev/null)"
    [[ -n "$height_candidate" ]] || continue
    (( height_candidate > current_height )) && current_height="$height_candidate"
  done
  consumed=$(( current_height > first_counted ? current_height - first_counted : 0 ))
  remaining_blocks=$(( max_blocks > consumed ? max_blocks - consumed : 0 ))
  remaining_seconds=$(( deadline > now ? deadline - now : 0 ))
  expired=false
  (( remaining_blocks == 0 || remaining_seconds == 0 )) && expired=true
  jq -cn --argjson first "$first_counted" --argjson current "$current_height" \
    --argjson remaining_blocks "$remaining_blocks" --argjson remaining_seconds "$remaining_seconds" --argjson expired "$expired" \
    '{first_counted_height:$first,current_height:$current,remaining_blocks:$remaining_blocks,
      remaining_seconds:$remaining_seconds,expired:$expired}'
}

# D: refuses once the manifest's own deadline/block budget is spent. A later
# deadline can only come from a new manifest (a new hash, new approvals);
# nothing here can extend the window for the currently admitted one.
recovery_validate_singleton_budget() {
  local manifest="$1" host="$2" budget
  [[ -n "$manifest" ]] || return 0
  budget="$(recovery_singleton_budget "$manifest" "$host")" || return 1
  [[ "$(jq -r '.expired' <<<"$budget")" == false ]] || {
    recovery_error 'singleton time/block budget has expired'
    return 1
  }
}

recovery_expiry_stop_artifact_path() {
  printf '%s/runs/%s/recovery/%s/expiry-stop/artifact.json\n' "$(recovery_evidence_root)" "$RECOVERY_RUN_ID" "$RECOVERY_HOST"
}

# Models what a future `stage` handler renders offline: a stop artifact
# binding the manifest's singleton deadline and its pre-signed expiry-stop
# approval. No host action; local evidence only, so activate can later
# prove the automatic stop is armed before the singleton window opens.
recovery_render_expiry_stop_artifact() {
  local manifest="$1" output="${2:-$(recovery_expiry_stop_artifact_path)}" deadline binding_json dir source
  deadline="$(jq -er '.singleton.singleton_deadline_utc' "$manifest")" || return 1
  binding_json="$(jq -c '.singleton.expiry_stop_approval_binding' "$manifest")" || return 1
  [[ "$binding_json" != null ]] || {
    recovery_error 'manifest has no expiry-stop approval binding to render'
    return 1
  }
  dir="$(dirname "$output")"
  recovery_safe_directory "$dir" create || {
    recovery_error 'unsafe expiry-stop artifact path'
    return 1
  }
  source="$(mktemp)"; chmod 600 "$source"
  jq -n --arg deadline "$deadline" --argjson binding "$binding_json" --arg rendered_at "$(date -u +%FT%TZ)" \
    '{armed:true,singleton_deadline_utc:$deadline,expiry_stop_approval_binding:$binding,rendered_at:$rendered_at}' >"$source"
  recovery_write_once "$output" "$source" || { rm -f "$source"; return 1; }
  rm -f "$source"
}

# Checked at activate admission: the artifact must exist, be armed, and
# name the exact deadline of the manifest activate is about to admit.
recovery_validate_expiry_stop_artifact() {
  local manifest="$1" artifact="${2:-$(recovery_expiry_stop_artifact_path)}" deadline
  [[ -n "$manifest" ]] || return 1
  deadline="$(jq -er '.singleton.singleton_deadline_utc' "$manifest")" || return 1
  recovery_require_private_file "$artifact" || {
    recovery_error 'expiry-stop artifact is missing or not a private file'
    return 1
  }
  jq -e --arg deadline "$deadline" '.armed == true and .singleton_deadline_utc == $deadline' "$artifact" >/dev/null || {
    recovery_error 'expiry-stop artifact is not armed or does not match the manifest deadline'
    return 1
  }
}

recovery_local_status() {
  local recovery_root latest='null' latest_finished='' item phase qualifier receipt selector finished details budget
  recovery_root="$(recovery_evidence_root)/runs/$RECOVERY_RUN_ID/recovery/$RECOVERY_HOST"
  recovery_safe_directory "$recovery_root" read || return 1
  if [[ -d "$recovery_root" ]]; then
    for item in inspect prepare freeze stage activate checkpoint retire rejoin resume:signers resume:poc resume:handoff verify:consensus verify:epochs verify:service abort; do
      phase="${item%%:*}"
      if [[ "$item" == *:* ]]; then qualifier="${item#*:}"; else qualifier=''; fi
      receipt="$(recovery_latest_receipt "$RECOVERY_HOST" "$phase" "$qualifier" 2>/dev/null || true)"
      [[ -n "$receipt" ]] || continue
      if recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt" >/dev/null 2>&1; then
        finished="$(jq -er '.finished_at' "$receipt")" || continue
        [[ -z "$latest_finished" || "$finished" > "$latest_finished" || "$finished" == "$latest_finished" ]] || continue
        selector="$phase"; [[ -z "$qualifier" ]] || selector="${phase}_$qualifier"
        latest="$(jq -c --arg path "$(recovery_receipt_relative_path "$receipt")" --arg selector "$selector" \
          '{phase,step,scope,verdict,mutation_state,finished_at,state:.details.state,path:$path,selector:$selector}' "$receipt")"
        latest_finished="$finished"
      fi
    done
  fi
  budget="$(recovery_singleton_budget "$RECOVERY_MANIFEST" "$RECOVERY_HOST")" || budget=null
  # D: an expired singleton budget overrides the ordinary progress state;
  # only status and abort remain available once it is spent.
  details="$(jq -cn --argjson latest "$latest" --argjson budget "$budget" '
    ($budget != null and $budget.expired) as $expired
    | {status:{
      operator_state:(if $expired then "EXPIRED" elif $latest == null then "NEW" else $latest.state end),
      runtime_state:"unknown",database_state:"unknown",
      remaining_seconds:(if $budget == null then null else $budget.remaining_seconds end),
      remaining_blocks:(if $budget == null then null else $budget.remaining_blocks end),
      missing_gate:(if $expired then "singleton window expired: abort or expiry-stop only"
        elif $latest == null then "inspect" else ("review " + $latest.selector + " receipt before the next mutation") end)
    }} + (if $budget == null then {} else {singleton_budget:$budget} end)
  ')"
  printf '%s\n' "$details" >"$RECOVERY_ATTEMPT_DIR/status.json"
  chmod 600 "$RECOVERY_ATTEMPT_DIR/status.json"
  recovery_terminal_receipt OBSERVED 0 none status_is_local_observation_only "$details"
}

recovery_parse_args() {
  local phase="$1" key value seen_options=''
  shift
  RECOVERY_PHASE="$phase"
  RECOVERY_INCIDENT=''; RECOVERY_HOST=''; RECOVERY_RUN_ID=''; RECOVERY_MANIFEST=''
  RECOVERY_APPROVAL=''; RECOVERY_CHECKPOINT=''; RECOVERY_OUTPUT=''; RECOVERY_SCOPE=''; RECOVERY_STEP=''
  RECOVERY_MANIFEST_SHA256=''; RECOVERY_PREDECESSOR_RECEIPTS='[]'; RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS=''
  RECOVERY_PENDING_APPROVAL_ID=''; RECOVERY_PENDING_APPROVAL_NONCE=''
  while (( $# )); do
    [[ "$1" == --* && $# -ge 2 && "$2" != --* ]] || { recovery_error 'options require explicit values'; return 2; }
    key="${1#--}"; value="$2"
    [[ " incident host run-id manifest approval checkpoint output scope step " == *" $key "* ]] || {
      recovery_error "unknown option --$key"; return 2;
    }
    [[ " $seen_options " != *" $key "* ]] || { recovery_error "duplicate option --$key"; return 2; }
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 2
    seen_options="${seen_options:+$seen_options }$key"
    case "$key" in
      incident) RECOVERY_INCIDENT="$value" ;; host) RECOVERY_HOST="$value" ;; run-id) RECOVERY_RUN_ID="$value" ;;
      manifest) RECOVERY_MANIFEST="$value" ;; approval) RECOVERY_APPROVAL="$value" ;; checkpoint) RECOVERY_CHECKPOINT="$value" ;;
      output) RECOVERY_OUTPUT="$value" ;; scope) RECOVERY_SCOPE="$value" ;; step) RECOVERY_STEP="$value" ;;
    esac
    shift 2
  done
  export RECOVERY_PHASE RECOVERY_INCIDENT RECOVERY_HOST RECOVERY_RUN_ID RECOVERY_MANIFEST RECOVERY_APPROVAL RECOVERY_CHECKPOINT RECOVERY_OUTPUT RECOVERY_SCOPE RECOVERY_STEP
  export RECOVERY_MANIFEST_SHA256 RECOVERY_PREDECESSOR_RECEIPTS RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS
  export RECOVERY_PENDING_APPROVAL_ID RECOVERY_PENDING_APPROVAL_NONCE
}

recovery_validate_cli_contract() {
  recovery_is_phase "$RECOVERY_PHASE" || { recovery_error "unknown phase: $RECOVERY_PHASE"; return 2; }
  [[ "$RECOVERY_HOST" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] || { recovery_error 'invalid recovery host'; return 2; }
  recovery_is_identifier "$RECOVERY_RUN_ID" || { recovery_error 'invalid recovery run ID'; return 2; }
  case "$RECOVERY_PHASE" in
    inspect)
      recovery_is_incident "$RECOVERY_INCIDENT" && [[ -n "$RECOVERY_OUTPUT" ]] || return 2
      [[ -z "$RECOVERY_MANIFEST$RECOVERY_APPROVAL$RECOVERY_CHECKPOINT$RECOVERY_SCOPE$RECOVERY_STEP" ]] || return 2
      ;;
    prepare|freeze|stage|activate|retire|abort)
      [[ -n "$RECOVERY_MANIFEST" && -n "$RECOVERY_APPROVAL" ]] || return 2
      [[ -z "$RECOVERY_INCIDENT$RECOVERY_CHECKPOINT$RECOVERY_OUTPUT$RECOVERY_SCOPE$RECOVERY_STEP" ]] || return 2
      ;;
    status)
      [[ -n "$RECOVERY_MANIFEST" && -z "$RECOVERY_INCIDENT$RECOVERY_APPROVAL$RECOVERY_CHECKPOINT$RECOVERY_OUTPUT$RECOVERY_SCOPE$RECOVERY_STEP" ]] || return 2
      ;;
    checkpoint)
      [[ -n "$RECOVERY_MANIFEST" && -n "$RECOVERY_OUTPUT" && -z "$RECOVERY_INCIDENT$RECOVERY_APPROVAL$RECOVERY_CHECKPOINT$RECOVERY_SCOPE$RECOVERY_STEP" ]] || return 2
      ;;
    rejoin)
      [[ -n "$RECOVERY_MANIFEST" && -n "$RECOVERY_CHECKPOINT" && -n "$RECOVERY_APPROVAL" ]] || return 2
      [[ -z "$RECOVERY_INCIDENT$RECOVERY_OUTPUT$RECOVERY_SCOPE$RECOVERY_STEP" ]] || return 2
      ;;
    resume)
      [[ "$RECOVERY_STEP" =~ ^(signers|poc|handoff)$ && -n "$RECOVERY_MANIFEST" && -n "$RECOVERY_APPROVAL" ]] || return 2
      [[ -z "$RECOVERY_INCIDENT$RECOVERY_CHECKPOINT$RECOVERY_OUTPUT$RECOVERY_SCOPE" ]] || return 2
      ;;
    verify)
      [[ "$RECOVERY_SCOPE" =~ ^(consensus|epochs|service)$ && -n "$RECOVERY_MANIFEST" ]] || return 2
      [[ -z "$RECOVERY_INCIDENT$RECOVERY_CHECKPOINT$RECOVERY_OUTPUT$RECOVERY_STEP" ]] || return 2
      if [[ "$RECOVERY_SCOPE" == service ]]; then [[ -n "$RECOVERY_APPROVAL" ]] || return 2; else [[ -z "$RECOVERY_APPROVAL" ]] || return 2; fi
      ;;
  esac
  local path
  for path in "$RECOVERY_MANIFEST" "$RECOVERY_APPROVAL" "$RECOVERY_CHECKPOINT"; do
    [[ -z "$path" ]] || recovery_canonical_input_file "$path" || { recovery_error "non-canonical input path: $path"; return 2; }
  done
  [[ -z "$RECOVERY_OUTPUT" ]] || recovery_canonical_output_path "$RECOVERY_OUTPUT" || {
    recovery_error 'output must be a new canonical path outside temporary storage'
    return 2
  }
}

recovery_preflight() {
  local approval_required=false
  RECOVERY_ADMISSION_REASON=admission_failed
  if [[ -n "$RECOVERY_MANIFEST" ]]; then
    RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$RECOVERY_MANIFEST")" || return 1
    export RECOVERY_MANIFEST_SHA256
  fi
  if [[ "$RECOVERY_PRIOR_ATTEMPT_INCOMPLETE" == true ]] && recovery_is_mutating_phase "$RECOVERY_PHASE"; then
    recovery_error 'a prior attempt has no terminal receipt; read back actual runtime and DB state before any retry'
    return 1
  fi
  if [[ -n "$RECOVERY_MANIFEST" ]]; then
    recovery_validate_manifest "$RECOVERY_MANIFEST" "$RECOVERY_HOST" "$RECOVERY_PHASE" || return 1
  fi
  # E4: every phase after prepare must match the coordinator machine that
  # produced the manifest; prepare (draft) and inspect (no manifest) are exempt.
  if [[ -n "$RECOVERY_MANIFEST" && "$RECOVERY_PHASE" != prepare ]]; then
    recovery_validate_controller_binding "$RECOVERY_MANIFEST" || {
      RECOVERY_ADMISSION_REASON=controller_mismatch
      return 1
    }
  fi
  # D: singleton-dependent phases refuse once the deadline or block budget
  # from the manifest and the last locally retained observation is spent;
  # only status and abort stay permitted (never checked here).
  case "$RECOVERY_PHASE" in
    checkpoint|retire|rejoin|resume|verify)
      recovery_validate_singleton_budget "$RECOVERY_MANIFEST" "$RECOVERY_HOST" || {
        RECOVERY_ADMISSION_REASON=singleton_expired
        return 1
      }
      ;;
  esac
  # D: activate refuses before the singleton window opens unless the
  # pre-rendered expiry-stop artifact is armed and bound to this exact
  # manifest deadline; a longer deadline requires a new manifest and its
  # own fresh approvals, never a code-side extension.
  if [[ "$RECOVERY_PHASE" == activate ]]; then
    recovery_validate_expiry_stop_artifact "$RECOVERY_MANIFEST" || {
      RECOVERY_ADMISSION_REASON=expiry_stop_not_armed
      return 1
    }
  fi
  recovery_is_mutating_phase "$RECOVERY_PHASE" && approval_required=true
  if [[ "$approval_required" == true ]]; then
    recovery_validate_approval "$RECOVERY_APPROVAL" || return 1
  fi
  if [[ "$RECOVERY_PHASE" == rejoin ]]; then
    recovery_validate_checkpoint "$RECOVERY_CHECKPOINT" || return 1
    recovery_validate_single_source_acceptance "$RECOVERY_MANIFEST" "$RECOVERY_APPROVAL" "$RECOVERY_HOST" || return 1
  fi
  recovery_collect_predecessors || return 1
}

recovery_run_registered_handler() {
  local handler="${RECOVERY_REGISTERED_HANDLERS[$RECOVERY_PHASE]:-}" result rc verdict mutation details reason errexit_was_set=false selector
  if [[ -z "$handler" ]]; then
    recovery_terminal_receipt REFUSED 3 none phase_mechanism_not_qualified '{}'
    recovery_error "phase $RECOVERY_PHASE has no qualified registered implementation"
    return 3
  fi
  # E3: an unqualified handler runs only under a signed lab authorization;
  # combat always needs a matching recovery/qualification.json record.
  selector="$(recovery_selector)"
  if ! recovery_authorize_handler_execution "$selector" "$handler"; then
    recovery_terminal_receipt REFUSED 3 none handler_not_qualified '{}'
    return 3
  fi
  # Consume the approval only when the handler is about to run.
  if ! recovery_consume_approval; then
    recovery_terminal_receipt REFUSED 3 none approval_already_consumed '{}'
    return 3
  fi
  if [[ $- == *e* ]]; then
    errexit_was_set=true
  fi
  set +e
  "$handler" "$RECOVERY_ATTEMPT_DIR"
  rc=$?
  [[ "$errexit_was_set" == true ]] && set -e
  result="$RECOVERY_ATTEMPT_DIR/phase-result.json"
  if [[ ! -f "$result" || -L "$result" ]]; then
    recovery_terminal_receipt INCONCLUSIVE 70 ambiguous handler_did_not_emit_terminal_result '{}'
    return 70
  fi
  chmod 600 "$result"
  jq -e '
    type == "object" and (keys | sort) == ["details","mutation_state","reason","verdict"]
    and (.verdict | IN("PASS","BLOCKED","INCONCLUSIVE","FAIL","FAILED","REFUSED"))
    and (.mutation_state | IN("none","planned","started","committed","partially_applied","stopped_preserved","ambiguous"))
    and (.reason | type == "string" and test("^[a-z][a-z0-9_]{0,127}$"))
    and (.details | type == "object")
  ' "$result" >/dev/null || {
    recovery_terminal_receipt INCONCLUSIVE 70 ambiguous invalid_handler_terminal_result '{}'
    return 70
  }
  verdict="$(jq -r .verdict "$result")"; mutation="$(jq -r .mutation_state "$result")"
  reason="$(jq -r .reason "$result")"; details="$(jq -c .details "$result")"
  if [[ "$RECOVERY_PHASE" == checkpoint && "$verdict" == PASS ]]; then
    recovery_validate_checkpoint_artifact || {
      recovery_terminal_receipt INCONCLUSIVE 70 "$mutation" checkpoint_artifact_missing_or_invalid '{}'
      return 70
    }
  fi
  if [[ "$RECOVERY_PHASE" == rejoin && "$verdict" == PASS ]]; then
    recovery_validate_rejoin_state_sync_evidence "$details" || {
      recovery_terminal_receipt INCONCLUSIVE 70 "$mutation" rejoin_state_sync_evidence_invalid '{}'
      return 70
    }
  fi
  if [[ "$RECOVERY_PHASE" == resume && "$RECOVERY_STEP" == signers && "$verdict" == PASS ]]; then
    recovery_validate_resume_signers_evidence "$details" || {
      recovery_terminal_receipt INCONCLUSIVE 70 "$mutation" resume_signers_evidence_invalid '{}'
      return 70
    }
  fi
  recovery_manifest_hash >/dev/null || {
    recovery_terminal_receipt FAILED 70 ambiguous manifest_changed_during_phase '{}'
    return 70
  }
  if (( rc == 0 )) && [[ "$verdict" != PASS ]]; then rc=3; fi
  if (( rc != 0 )) && [[ "$verdict" == PASS ]]; then verdict=INCONCLUSIVE; reason=handler_exit_conflicts_with_pass; fi
  recovery_terminal_receipt "$verdict" "$rc" "$mutation" "$reason" "$details" || return 70
  return "$rc"
}

recovery_main() {
  local phase="${1:-}" rc=0 phase_root phase_path qualifier='' evidence_root evidence_root_input
  shift || true
  recovery_parse_args "$phase" "$@" || return $?
  recovery_validate_cli_contract || return $?

  # gdc normally selects a per-host GDC_HOME before entering this library.
  # Direct callers receive the same canonicalization and never write to /.
  init_gdc_paths
  [[ "$GDC_HOME" == /* && "$GDC_HOME" != / ]] || { recovery_error 'unsafe GDC_HOME'; return 2; }
  [[ "$GDC_HOME" =~ ^/[A-Za-z0-9._@+/-]+$ ]] || { recovery_error 'GDC_HOME is not a canonical recovery evidence path'; return 2; }
  case "$GDC_HOME" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/tmp|/var/tmp/*)
      recovery_error 'GDC_HOME for recovery evidence must use persistent storage'
      return 2
      ;;
  esac
  # The launcher sets this before switching GDC_HOME to a Host-specific
  # runtime home. Direct callers use their current GDC_HOME as the compatible
  # one-host evidence root.
  evidence_root_input="$(recovery_evidence_root)"
  evidence_root="$(realpath -m -- "$evidence_root_input")"
  [[ "$evidence_root_input" == "$evidence_root" ]] || {
    recovery_error 'GDC_RECOVERY_ROOT must be an exact canonical non-symlink path'
    return 2
  }
  [[ "$evidence_root" == /* && "$evidence_root" != / ]] || { recovery_error 'unsafe GDC_RECOVERY_ROOT'; return 2; }
  [[ "$evidence_root" =~ ^/[A-Za-z0-9._@+/-]+$ ]] || { recovery_error 'GDC_RECOVERY_ROOT is not a canonical recovery evidence path'; return 2; }
  case "$evidence_root" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/tmp|/var/tmp/*)
      recovery_error 'GDC_RECOVERY_ROOT for recovery evidence must use persistent storage'
      return 2
      ;;
  esac
  recovery_safe_directory "$evidence_root" create || {
    recovery_error 'GDC_RECOVERY_ROOT contains a forbidden symlink or non-directory component'
    return 2
  }
  # Do not export a derived fallback: a direct caller can change GDC_HOME
  # between independent runs and must retain the legacy one-home behaviour.
  if [[ -n "${GDC_RECOVERY_ROOT:-}" ]]; then
    GDC_RECOVERY_ROOT="$evidence_root"
    export GDC_RECOVERY_ROOT
  fi
  umask 077
  [[ -z "$RECOVERY_STEP" ]] || qualifier="$RECOVERY_STEP"
  [[ -z "$RECOVERY_SCOPE" ]] || qualifier="$RECOVERY_SCOPE"
  phase_path="$(recovery_phase_storage_path "$RECOVERY_PHASE" "$qualifier")" || return 70
  phase_root="$evidence_root/runs/$RECOVERY_RUN_ID/recovery/$RECOVERY_HOST/$phase_path"
  recovery_next_attempt "$phase_root" || return 70
  RECOVERY_STARTED_AT="$(date -u +%FT%TZ)"
  export RECOVERY_STARTED_AT
  recovery_record_command "$@"

  if ! recovery_preflight; then
    recovery_terminal_receipt REFUSED 3 none "${RECOVERY_ADMISSION_REASON:-admission_failed}" '{}' || return 70
    return 3
  fi

  case "$RECOVERY_PHASE" in
    inspect) recovery_local_inspect || rc=$? ;;
    status) recovery_local_status || rc=$? ;;
    *) recovery_run_registered_handler || rc=$? ;;
  esac
  if (( rc == 0 )) && [[ "$RECOVERY_PHASE" == inspect || "$RECOVERY_PHASE" == checkpoint ]]; then
    recovery_export_receipt || return 70
  fi
  printf 'RECOVERY phase=%s host=%s run_id=%s verdict=%s receipt=%s\n' \
    "$RECOVERY_PHASE" "$RECOVERY_HOST" "$RECOVERY_RUN_ID" \
    "$(jq -r .verdict "$RECOVERY_ATTEMPT_DIR/receipt.json")" "$RECOVERY_ATTEMPT_DIR/receipt.json"
  return "$rc"
}
