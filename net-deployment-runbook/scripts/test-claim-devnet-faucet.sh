#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/bin"
cp "$ROOT/scripts/claim-devnet-faucet.sh" "$tmp/scripts/claim-devnet-faucet.sh"
cat >"$tmp/scripts/lib.sh" <<'LIB'
die() { echo "error: $*" >&2; exit 1; }
load_project() { GENESIS_PUBLIC_HOST=node0.example.test; }
curl_exit_status() { printf 'exit_%s' "$1"; }
LIB
# The fake faucet answers the POSTs from GDC_TEST_CLAIM_CODES in order and
# reports a funded balance on every GET.
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *' -X POST '* ]]; then
  count="$(cat "$GDC_TEST_STATE/posts" 2>/dev/null || echo 0)"
  count=$((count + 1)); printf '%s\n' "$count" >"$GDC_TEST_STATE/posts"
  read -r -a codes <<<"$GDC_TEST_CLAIM_CODES"
  code="${codes[$((count - 1))]:-${codes[-1]}}"
  case "$code" in
    000) printf '\n000'; exit 7 ;;
    202) printf '{"txhash":"%064d"}\n202' 1 ;;
    429) printf '{"detail":"claim limit reached for this address or source"}\n429' ;;
    *) printf '{}\n%s' "$code" ;;
  esac
  exit 0
fi
output=''
while (($#)); do [[ "$1" == -o ]] && output="$2"; shift; done
printf '{"balances":[{"denom":"ngonka","amount":"100000000000"}]}' >"$output"
printf '200'
CURL
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod 0755 "$tmp/bin/curl" "$tmp/bin/sleep"
address=gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
claim() {
  local name="$1" codes="$2"
  mkdir -p "$tmp/$name"
  PATH="$tmp/bin:$PATH" GDC_TEST_STATE="$tmp/$name" GDC_TEST_CLAIM_CODES="$codes" \
    bash "$tmp/scripts/claim-devnet-faucet.sh" "$address" >"$tmp/$name/out" 2>"$tmp/$name/err"
}

claim flaky '502 000 202'
[[ "$(cat "$tmp/flaky/posts")" == 3 ]]
grep -Fq 'WAIT DevNet faucet unavailable http_status=502 attempt=1/6' "$tmp/flaky/out"
grep -Fq 'WAIT DevNet faucet unavailable http_status=000 attempt=2/6' "$tmp/flaky/out"
grep -Fq 'READY faucet submitted funding' "$tmp/flaky/out"
grep -Fq 'PASS DevNet faucet funded' "$tmp/flaky/out"

# The first POST was accepted but its answer was lost: the retry sees 409 and
# the balance decides.
claim lost-answer '504 409'
[[ "$(cat "$tmp/lost-answer/posts")" == 2 ]]
grep -Fq 'READY faucet claim already exists' "$tmp/lost-answer/out"
grep -Fq 'PASS DevNet faucet funded' "$tmp/lost-answer/out"

# A refusal is an answer, not an outage.
if claim refused '429 202'; then echo 'a refused faucet claim was retried into success' >&2; exit 1; fi
[[ "$(cat "$tmp/refused/posts")" == 1 ]]
grep -Fq 'DevNet faucet rejected funding request (HTTP 429): claim limit reached' "$tmp/refused/err"

if claim down '503'; then echo 'an unavailable faucet unexpectedly funded the Host' >&2; exit 1; fi
[[ "$(cat "$tmp/down/posts")" == 6 ]]
grep -Fq 'DevNet faucet rejected funding request (HTTP 503)' "$tmp/down/err"
printf 'PASS faucet claim retries an unavailable faucet, keeps a refusal final and stays single-funded\n'
