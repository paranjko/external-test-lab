#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Use the archive format created by the runbook itself.  The fake interpreter
# turns any accidental Python call into a deterministic test failure.
mkdir -p "$tmp/source/tmkms/secrets" "$tmp/source/tmkms/state" \
  "$tmp/source/inference/config" "$tmp/bin"
printf 'chain = "gonka-fixture"\n' >"$tmp/source/tmkms/tmkms.toml"
printf 'key\n' >"$tmp/source/tmkms/secrets/priv_validator_key.softsign"
printf 'identity\n' >"$tmp/source/tmkms/secrets/kms-identity.key"
printf '{}\n' >"$tmp/source/tmkms/state/priv_validator_state.json"
printf '{}\n' >"$tmp/source/inference/config/node_key.json"
(
  cd "$tmp/source"
  tar --format=ustar -cf "$tmp/remote-state.tar" tmkms inference
)
cat >"$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo 'unexpected python3 invocation on cleanroom restore path' >&2
exit 97
EOF
chmod +x "$tmp/bin/python3"

PATH="$tmp/bin:$PATH" GDC_VALIDATOR_BACKUP_TEST_MODE=true \
  "$ROOT/scripts/validator-backup.sh" inspect-archive remote-state \
  "$tmp/remote-state.tar" "$tmp/extracted" gdc-node1
[[ -f "$tmp/extracted/tmkms/tmkms.toml" ]]
[[ -f "$tmp/extracted/inference/config/node_key.json" ]]
printf 'PASS cleanroom validator restore archive inspection requires no Python\n'
