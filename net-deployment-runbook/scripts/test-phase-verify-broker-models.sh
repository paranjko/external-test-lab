#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
RUN="$tmp/run"; mkdir -p "$RUN"
export MODEL_ID='Qwen/Qwen3-0.6B'
PATH="$tmp/bin:$PATH"; mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=''; status=200; url=''
while (($#)); do case "$1" in -o) out="$2"; shift 2;; -w) shift 2;; *) url="$1"; shift;; esac; done
printf '%s\n' "$url" >>"$CURL_LOG"
case "${FAKE_BROKER_MODE:-pass}" in
 first-down) [[ "$url" == *one.broker* ]] && { status=503; body='{}'; } || body='{"data":[{"id":"Qwen/Qwen3-0.6B"}]}' ;;
 broker-down) status=503; body='{}' ;;
 transport) body='{}'; printf '%s' "$body" >"$out"; printf '000'; exit 7 ;;
 malformed) body='not-json' ;;
 missing-list) body='{}' ;;
 missing-model) body='{"data":[]}' ;;
 *) body='{"data":[{"id":"Qwen/Qwen3-0.6B"}]}' ;;
esac
printf '%s' "$body" >"$out"; printf '%s' "$status"
EOF
chmod +x "$tmp/bin/curl"
# shellcheck disable=SC1090
source <(sed -n '/^fetch_broker_models()/,/^}/p' "$ROOT/scripts/phase-verify.sh")
die() { return 1; }
descriptor="$tmp/gonka-fixture.json"
cat >"$descriptor" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://one.example/chain-rpc","p2p":"tcp://one.example:5000","api":"https://one.example"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://two.example/chain-rpc","p2p":"tcp://two.example:5000"}],"brokers":[{"api_urls":["https://one.broker.example","https://two.broker.example"]}]}
EOF
BOOTSTRAP_DESCRIPTOR="$descriptor"; export API_HOST='fallback.example'; CURL_LOG="$tmp/curl.log"; export CURL_LOG
FAKE_BROKER_MODE=first-down fetch_broker_models
grep -qx 'https://one.broker.example/v1/models' "$CURL_LOG"
grep -qx 'https://two.broker.example/v1/models' "$CURL_LOG"
! grep -q 'fallback.example' "$CURL_LOG"
for mode in transport broker-down malformed missing-list missing-model; do
  : >"$CURL_LOG"
  if FAKE_BROKER_MODE="$mode" fetch_broker_models >/dev/null 2>&1; then echo "accepted $mode broker response" >&2; exit 1; fi
  grep -q 'one.broker.example/v1/models' "$CURL_LOG"
done
rm -f "$BOOTSTRAP_DESCRIPTOR"; : >"$CURL_LOG"
FAKE_BROKER_MODE=pass fetch_broker_models
grep -qx 'https://fallback.example/v1/models' "$CURL_LOG"
grep -Fq 'CHAIN_BASE' "$ROOT/scripts/phase-verify.sh"
! grep -Fq 'CHAIN_BASE/v1/models' "$ROOT/scripts/phase-verify.sh"
printf 'PASS broker model verification is ordered, fail-closed, and separate from chain reads\n'
