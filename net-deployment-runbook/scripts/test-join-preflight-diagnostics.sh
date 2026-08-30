#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  *node0.example.test*) id=0123456789abcdef0123456789abcdef01234567 ;;
  *node1.example.test*) id=89abcdef0123456789abcdef0123456789abcdef ;;
  *) exit 2 ;;
esac
case "$url" in
  */status) printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community","version":"0.2.14"}}}\n' "$id" ;;
  */abci_info) printf '{"result":{"response":{"version":"0.2.14"}}}\n' ;;
  */v1/versions) printf '{"node_version":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"version":"0.2.14-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}\n' ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"

if PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --skip-qualification validator-a >"$tmp/out" 2>"$tmp/err"; then
  echo 'unsafe mixed seed observation unexpectedly entered JOIN' >&2
  exit 1
fi
grep -Fq 'software_upgrade_required:' "$tmp/err"
grep -Fq "preflight_receipt=$tmp/operator/gdc-node2/preflight-receipt.env" "$tmp/err" || \
  grep -Fq 'preflight_receipt=' "$tmp/err"
pointer="$tmp/operator/reporting/failures/latest-failure"
failure_id="$(<"$pointer")"
failure="$tmp/operator/reporting/invocations/invocation.$failure_id/failure.env"
grep -qx 'failure_stage=join-preflight' "$failure"
grep -qx 'active_phase=join-preflight' "$failure"
diagnostic="$(awk -F= '$1 == "diagnostic_envelope" { print $2; exit }' "$failure")"
[[ -n "$diagnostic" && -f "$diagnostic" && ! -L "$diagnostic" ]]
receipt="$(awk -F= '$1 == "preflight_receipt" { print $2; exit }' "$failure")"
[[ -n "$receipt" && -f "$receipt" && ! -L "$receipt" ]]
grep -qx 'checkpoint=software-observation' "$receipt"
grep -qx 'result=failed' "$receipt"
"$ROOT/scripts/diagnostic-envelope.sh" validate "$diagnostic"
jq -e '
  .command_family == "join" and .phase == "join-preflight" and
  .checkpoint == "software-observation" and .state == "unavailable" and
  .category == "network" and .tool == "seed-observer" and
  .resume.decision == "safe" and .resume.token == "join-repeat"
' "$diagnostic" >/dev/null

printf 'PASS JOIN preflight retains a typed diagnostic before Host mutation\n'
