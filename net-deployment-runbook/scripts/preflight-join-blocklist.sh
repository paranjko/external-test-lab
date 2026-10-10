#!/usr/bin/env bash
# Read-only preflight: derive the retained cold mnemonic's account address in
# an isolated local keyring and compare it with the chain's blocked
# participant list before any Host mutation. The address never leaves this
# machine: it is neither printed nor written to the refusal receipt.
set -Eeuo pipefail

usage() { echo "Usage: $0 --mnemonic-file FILE --bootstrap-file FILE --output FILE" >&2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MNEMONIC_FILE=''; BOOTSTRAP_FILE=''; OUTPUT=''
while (($#)); do case "$1" in
  --mnemonic-file) [[ -z "$MNEMONIC_FILE" && -n "${2:-}" ]] || { usage; exit 2; }; MNEMONIC_FILE="$2"; shift 2 ;;
  --bootstrap-file) [[ -z "$BOOTSTRAP_FILE" && -n "${2:-}" ]] || { usage; exit 2; }; BOOTSTRAP_FILE="$2"; shift 2 ;;
  --output) [[ -z "$OUTPUT" && -n "${2:-}" ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ -n "$MNEMONIC_FILE" && -n "$BOOTSTRAP_FILE" && -n "$OUTPUT" ]] || { usage; exit 2; }
[[ -f "$MNEMONIC_FILE" && ! -L "$MNEMONIC_FILE" && -r "$MNEMONIC_FILE" && -s "$MNEMONIC_FILE" ]] \
  || { echo 'ERROR join blocklist preflight: the retained cold mnemonic is not a readable regular file' >&2; exit 2; }
[[ -r "$BOOTSTRAP_FILE" ]] || { echo 'ERROR join blocklist preflight: the validated Bootstrap file is unreadable' >&2; exit 2; }
command -v curl >/dev/null || { echo 'ERROR join blocklist preflight: curl is required' >&2; exit 2; }
command -v jq >/dev/null || { echo 'ERROR join blocklist preflight: jq is required' >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
chmod 700 "$work"
printf '%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" >"$work/password"
chmod 0600 "$work/password"
password="$(<"$work/password")"

run_inferenced() {
  # GDC_BLOCKLIST_INFERENCED_BIN is a test-only seam with the same contract as
  # the recovery derivation helper: an exact CLI path, never a PATH lookup.
  if [[ -n "${GDC_BLOCKLIST_INFERENCED_BIN:-}" ]]; then
    [[ "$GDC_BLOCKLIST_INFERENCED_BIN" == /* && -x "$GDC_BLOCKLIST_INFERENCED_BIN" ]] \
      || { echo 'ERROR join blocklist preflight: the inferenced CLI is unavailable' >&2; return 1; }
    "$GDC_BLOCKLIST_INFERENCED_BIN" --home "$work/keyring" "$@"
  else
    # Address derivation is independent of the target Host runtime. Use the
    # configured local operator CLI before any SSH operation; a later JOIN
    # profile still pins every Host-side artifact independently.
    "$ROOT/scripts/ensure-inferenced-cli.sh" >/dev/null
    INFERENCED_HOME="$work/keyring" "$ROOT/scripts/inferenced.sh" "$@"
  fi
}

if ! printf '%s\n%s\n%s\n' "$(cat "$MNEMONIC_FILE")" "$password" "$password" \
  | run_inferenced keys add gdc-blocklist-check --recover --keyring-backend file \
    >"$work/keys-add.out" 2>&1; then
  echo 'ERROR join blocklist preflight: the supplied mnemonic could not be imported into an isolated keyring' >&2
  exit 2
fi
address="$(printf '%s\n' "$password" | run_inferenced keys show gdc-blocklist-check --keyring-backend file -a 2>/dev/null | tail -n1 | tr -d '\r')"
[[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] \
  || { echo 'ERROR join blocklist preflight: the supplied mnemonic did not produce a valid account address' >&2; exit 2; }

# Read the blocked participant list from every validated Bootstrap seed and
# Broker API endpoint until one answers with a well-formed response. A run
# that cannot prove the account is allowed must not mutate the Host.
blocklist_response=''; blocklist_read=false
mapfile -t endpoints < <(jq -r '
  [(.seeds[]? | (.api // empty)), (.brokers[]?.api_urls[]?)] | map(select(startswith("https://"))) | unique | .[]
' "$BOOTSTRAP_FILE")
for endpoint in "${endpoints[@]}"; do
  response="$(curl -fsS --max-time 20 "${endpoint%/}/chain-api/productscience/inference/inference/params" 2>/dev/null)" || continue
  if jq -e '
    .params.participant_access_params.blocked_participant_addresses
    | type == "array" and length <= 1024
    and all(.[]; type == "string" and test("^gonka1[0-9a-z]{20,90}$"))
  ' <<<"$response" >/dev/null 2>&1; then
    blocklist_response="$response"
    blocklist_read=true
    break
  fi
done
[[ "$blocklist_read" == true ]] || {
  echo 'ERROR join blocklist preflight: no Bootstrap seed or Broker answered with a valid participant blocklist' >&2
  exit 2
}

if ! jq -e --arg address "$address" \
  '.params.participant_access_params.blocked_participant_addresses | index($address) != null' \
  <<<"$blocklist_response" >/dev/null; then
  printf 'PASS the supplied mnemonic is not on the chain participant blocklist\n'
  exit 0
fi

# Blocked: retain a bounded, mode-restricted refusal receipt. It must not
# contain the derived address, the mnemonic, or any raw network response.
summary='The supplied mnemonic derives a participant address that the chain currently blocks from operating a validator. Supply a different cold mnemonic or request removal from the blocklist.'
mkdir -p "$(dirname "$OUTPUT")"
tmp="$(mktemp "$(dirname "$OUTPUT")/.blocklist-refusal.XXXXXX")"
jq -n --arg run_id "${GDC_RUN_ID:-unknown}" --arg node "${GDC_JOIN_NODE_NAME:-unknown}" --arg summary "$summary" \
  '{schema_version:1,kind:"gdc-join-blocklist-refusal",run_id:$run_id,node_name:$node,
    reason:"mnemonic_participant_blocked",created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),summary:$summary}' >"$tmp"
chmod 0600 "$tmp"
jq -e '
  type == "object" and (keys | sort) == ["created_at","kind","node_name","reason","run_id","schema_version","summary"] and
  .schema_version == 1 and .kind == "gdc-join-blocklist-refusal" and .reason == "mnemonic_participant_blocked" and
  (.run_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
  (.node_name | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
  (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and
  (.summary | type == "string" and length <= 240 and test("^[[:print:]]*$"))
' "$tmp" >/dev/null || { rm -f "$tmp"; echo 'ERROR join blocklist preflight: refusal receipt failed validation' >&2; exit 2; }
mv -f "$tmp" "$OUTPUT"
chmod 0600 "$OUTPUT"
printf 'REFUSED the supplied mnemonic derives a participant address currently blocked from operating a validator; use a new eligible cold mnemonic and do not retry this one\n' >&2
exit 65
