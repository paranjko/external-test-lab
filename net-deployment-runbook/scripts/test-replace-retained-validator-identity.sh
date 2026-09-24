#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/dai/identity/p2p" "$tmp/dai/signer/tmkms/secrets" "$tmp/dai/identity-bootstrap"
printf '{}\n' >"$tmp/dai/identity/p2p/node_key.json"
printf 'signer\n' >"$tmp/dai/signer/tmkms/secrets/priv_validator_key.softsign"
printf '{}\n' >"$tmp/dai/identity-bootstrap/node7.json"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "${GDC_TEST_DOCKER_ERROR:-false}" != true ]] || exit 125
[[ "${GDC_TEST_SIGNER_RUNNING:-false}" != true ]] || printf 'container-id\n'
EOF
chmod 0755 "$tmp/bin/docker"

PATH="$tmp/bin:$PATH" GDC_REMOTE_IDENTITY_ROOT="$tmp/dai" \
  "$ROOT/scripts/replace-retained-validator-identity.sh" node7 fixture-run >"$tmp/receipt.json"
jq -e '
  .kind == "gdc-retained-validator-identity-replacement" and
  .node_name == "node7" and .run_id == "fixture-run" and
  .signer_was_running == false and .identity_removed == true and
  (.archive_sha256 | test("^[0-9a-f]{64}$"))
' "$tmp/receipt.json" >/dev/null
[[ ! -e "$tmp/dai/identity" && ! -e "$tmp/dai/signer" && ! -e "$tmp/dai/identity-bootstrap/node7.json" ]]
archive="$(jq -r .archive "$tmp/receipt.json")"
tar -tf "$archive" | grep -Fxq 'identity/p2p/node_key.json'
tar -tf "$archive" | grep -Fxq 'signer/tmkms/secrets/priv_validator_key.softsign'
PATH="$tmp/bin:$PATH" GDC_REMOTE_IDENTITY_ROOT="$tmp/dai" \
  "$ROOT/scripts/replace-retained-validator-identity.sh" node7 fixture-run >"$tmp/repeated.json"
cmp -s "$tmp/receipt.json" "$tmp/repeated.json"

mkdir -p "$tmp/dai/identity/p2p" "$tmp/dai/signer/tmkms/secrets"
printf '{}\n' >"$tmp/dai/identity/p2p/node_key.json"
printf 'signer\n' >"$tmp/dai/signer/tmkms/secrets/priv_validator_key.softsign"
if PATH="$tmp/bin:$PATH" GDC_TEST_SIGNER_RUNNING=true GDC_REMOTE_IDENTITY_ROOT="$tmp/dai" \
    "$ROOT/scripts/replace-retained-validator-identity.sh" node8 fixture-run >"$tmp/running.out" 2>"$tmp/running.err"; then
  echo 'running retained signer was replaced' >&2
  exit 1
fi
grep -Fq 'retained validator signer is still running' "$tmp/running.err"
[[ -s "$tmp/dai/identity/p2p/node_key.json" && -s "$tmp/dai/signer/tmkms/secrets/priv_validator_key.softsign" ]]
[[ ! -e "$tmp/dai/rejoin/node8/replaced-fixture-run.tar" ]]

rm -rf -- "$tmp/dai/identity" "$tmp/dai/signer"
mkdir -p "$tmp/dai/identity/p2p" "$tmp/dai/signer/tmkms/secrets"
printf '{}\n' >"$tmp/dai/identity/p2p/node_key.json"
printf 'signer\n' >"$tmp/dai/signer/tmkms/secrets/priv_validator_key.softsign"
if PATH="$tmp/bin:$PATH" GDC_TEST_DOCKER_ERROR=true GDC_REMOTE_IDENTITY_ROOT="$tmp/dai" \
    "$ROOT/scripts/replace-retained-validator-identity.sh" node10 fixture-run >"$tmp/docker-error.out" 2>"$tmp/docker-error.err"; then
  echo 'unverifiable retained signer state was accepted' >&2
  exit 1
fi
grep -Fq 'signer state cannot be verified' "$tmp/docker-error.err"
[[ -s "$tmp/dai/identity/p2p/node_key.json" && -s "$tmp/dai/signer/tmkms/secrets/priv_validator_key.softsign" ]]
[[ ! -e "$tmp/dai/rejoin/node10/replaced-fixture-run.tar" ]]

rm -rf -- "$tmp/dai/identity" "$tmp/dai/signer"
mkdir -p "$tmp/dai/identity/p2p" "$tmp/dai/real-signer/tmkms/secrets"
printf '{}\n' >"$tmp/dai/identity/p2p/node_key.json"
printf 'signer\n' >"$tmp/dai/real-signer/tmkms/secrets/priv_validator_key.softsign"
ln -s "$tmp/dai/real-signer" "$tmp/dai/signer"
if PATH="$tmp/bin:$PATH" GDC_REMOTE_IDENTITY_ROOT="$tmp/dai" \
    "$ROOT/scripts/replace-retained-validator-identity.sh" node9 fixture-run >"$tmp/symlink.out" 2>"$tmp/symlink.err"; then
  echo 'symlinked retained signer was replaced' >&2
  exit 1
fi
grep -Fq 'refuses symlinked state roots' "$tmp/symlink.err"
[[ -s "$tmp/dai/real-signer/tmkms/secrets/priv_validator_key.softsign" ]]

printf 'PASS retained validator identity replacement is stopped-signer-only and archived\n'
