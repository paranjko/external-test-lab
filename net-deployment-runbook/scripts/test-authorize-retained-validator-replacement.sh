#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
participants="$tmp/participants.json"
key_a="$(printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | base64 -w0)"
key_b="$(printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' | base64 -w0)"
key_c="$(printf 'cccccccccccccccccccccccccccccccc' | base64 -w0)"
address_a=gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
address_b=gonka1pppppppppppppppppppppppppppppppppppppp

jq -cn --arg a "$address_a" --arg b "$address_b" --arg ka "$key_a" --arg kb "$key_b" \
  '{participant:[{address:$a,validator_key:$ka},{address:$b,validator_key:$kb}]}' >"$participants"

"$ROOT/scripts/authorize-retained-validator-replacement.sh" "$participants" "$address_a" "$key_a" \
  | jq -e --arg key "$key_a" '.mode == "registered_match" and .registered_key == $key' >/dev/null
"$ROOT/scripts/authorize-retained-validator-replacement.sh" "$participants" "$address_a" "$key_c" \
  | jq -e --arg key "$key_a" '.mode == "unregistered_orphan" and .registered_key == $key' >/dev/null

if "$ROOT/scripts/authorize-retained-validator-replacement.sh" "$participants" "$address_a" "$key_b" >/dev/null 2>&1; then
  echo 'replacement accepted a validator key registered to another participant' >&2
  exit 1
fi
jq '.participant += [.participant[0]]' "$participants" >"$tmp/duplicate.json"
if "$ROOT/scripts/authorize-retained-validator-replacement.sh" "$tmp/duplicate.json" "$address_a" "$key_c" >/dev/null 2>&1; then
  echo 'replacement accepted an ambiguous participant set' >&2
  exit 1
fi

printf 'PASS retained validator replacement accepts only the mnemonic participant key or an unregistered stopped key\n'
