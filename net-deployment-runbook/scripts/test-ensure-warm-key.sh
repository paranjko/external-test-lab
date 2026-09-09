#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
expected='gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
mkdir -p "$tmp/bin" "$tmp/deploy"
cat >"$tmp/deploy/.env" <<EOF
KEY_NAME=gdc-node2-warm
KEYRING_PASSWORD=test-password
EOF
: >"$tmp/deploy/compose.yaml"
install -m 0755 "$ROOT/02-node/ensure-warm-key.sh" "$tmp/deploy/ensure-warm-key.sh"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
command="$*"
if [[ "$command" == *'keys show'* ]]; then
  [[ -e "$FAKE_KEY_PRESENT" ]] || exit 1
  printf '%s\n' "${FAKE_KEY_ADDRESS:-}"
  exit 0
fi
if [[ "$command" == *'keys add'* ]]; then
  : >"$FAKE_KEY_PRESENT"
  exit 0
fi
echo "unexpected docker invocation: $command" >&2
exit 97
EOF
chmod 0755 "$tmp/bin/docker"

printf '%s\n' 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour' \
  | PATH="$tmp/bin:$PATH" FAKE_KEY_PRESENT="$tmp/key-present" FAKE_KEY_ADDRESS="$expected" \
    "$tmp/deploy/ensure-warm-key.sh" --expected-address "$expected" \
    >"$tmp/import.out" 2>"$tmp/import.err" \
    || { cat "$tmp/import.err" >&2; exit 1; }
grep -Fxq 'READY promoted warm key matches restored identity' "$tmp/import.out"
[[ -e "$tmp/key-present" ]]

if printf '%s\n' 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour' \
  | PATH="$tmp/bin:$PATH" FAKE_KEY_PRESENT="$tmp/key-present" FAKE_KEY_ADDRESS='gonka1wrongwrongwrongwrongwrongwrongwrongwrongwrong' \
    "$tmp/deploy/ensure-warm-key.sh" --expected-address "$expected" \
    >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"; then
  echo 'warm-key binding accepted a mismatched existing identity' >&2
  exit 1
fi
grep -Fq 'promoted warm key does not match the restored public identity' "$tmp/mismatch.err"
printf 'PASS promoted generation receives only the verified warm identity\n'
