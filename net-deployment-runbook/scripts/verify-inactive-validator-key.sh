#!/usr/bin/env bash
# Authorize an explicit validator-backup restore only while its exact
# consensus key is outside the complete current validator set.  This is not a
# claim about arbitrary copies of a private key; it prevents restoration from
# enabling a key that is already able to sign consensus blocks.
set -Eeuo pipefail
umask 077

usage() {
  echo "Usage: $0 --identity IDENTITY.json --validators validators.json --output receipt.json" >&2
}

identity=''
validators=''
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) identity="${2:-}"; shift 2 ;;
    --validators) validators="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -r "$identity" && -r "$validators" && -n "$output" ]] || { usage; exit 2; }
key="$(jq -er '.consensus_pubkey | select(type == "string" and test("^[A-Za-z0-9+/]{43}=$"))' "$identity")" \
  || { echo 'validator inactivity check: identity lacks a canonical consensus key' >&2; exit 1; }
[[ "$(base64 -d <<<"$key" 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
  || { echo 'validator inactivity check: consensus key is not Ed25519' >&2; exit 1; }

jq -e --arg key "$key" '
  .result as $result
  | ($result.validators | type) == "array"
  and ($result.total | type) == "string" and ($result.total | test("^[1-9][0-9]*$"))
  and ($result.count | type) == "string" and ($result.count | test("^[1-9][0-9]*$"))
  and ($result.block_height | type) == "string" and ($result.block_height | test("^[1-9][0-9]*$"))
  and (($result.total | tonumber) == ($result.count | tonumber))
  and (($result.count | tonumber) == ($result.validators | length))
  and all($result.validators[];
    ((.pub_key.value | type) == "string")
    and ((.voting_power | type) == "string")
    and ((.voting_power | test("^[0-9]+$")))
    and (.pub_key.value != $key))
' "$validators" >/dev/null \
  || { echo 'validator inactivity check: consensus key is present or validator response is incomplete' >&2; exit 1; }

parent="$(dirname "$output")"
install -d -m 0700 "$parent"
temporary="$(mktemp "$parent/.inactive-validator-key.XXXXXX")"
validators_sha256="$(sha256sum "$validators" | awk '{print $1}')"
jq -n --arg key "$key" --arg sha "$validators_sha256" --arg observed "$(date -u +%FT%TZ)" \
  --slurpfile validators "$validators" '
  {schema_version:1,kind:"gdc-inactive-validator-key-fence",
   method:"complete_public_validator_set_absence",consensus_pubkey:$key,
   validator_set_height:$validators[0].result.block_height,
   validator_set_total:($validators[0].result.total|tonumber),
   validator_set_sha256:$sha,observed_at:$observed}
' >"$temporary"
chmod 600 "$temporary"
mv -f -- "$temporary" "$output"
printf 'PASS validator backup key is absent from complete validator set height=%s total=%s\n' \
  "$(jq -r .validator_set_height "$output")" "$(jq -r .validator_set_total "$output")"
