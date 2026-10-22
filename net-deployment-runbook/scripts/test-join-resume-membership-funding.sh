#!/usr/bin/env bash
# Active participant status does not prove that its retained cold account is
# funded. Exercise the membership resume funding gate without network access.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/scripts"
cat >"$tmp/scripts/claim-devnet-faucet.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 1 && "$1" == gonka1fixtureparticipant ]]
printf '%s\n' "$1" >>"$GDC_TEST_CLAIMS"
EOF
chmod 0755 "$tmp/scripts/claim-devnet-faucet.sh"
eval "$(sed -n '/^ensure_membership_funding() {$/,/^}$/p' "$ROOT/scripts/phase-join-resume-membership.sh")"

run_case() (
  local state="$1" mode="$2" expect_claim="$3"
  export ROOT="$tmp" NODE=fixture GENESIS_PUBLIC_HOST=genesis.example.test
  export GDC_FAUCET_CLAIM_NGONKA=100000000000 GDC_TEST_MODE="$mode" GDC_TEST_CLAIMS="$tmp/claims"
  : >"$GDC_TEST_CLAIMS"
  step() { printf '%s\n' "$*" >>"$tmp/steps"; }
  curl() {
    local output='' url=''
    while (($#)); do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        -w) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    [[ "$url" == "https://genesis.example.test/chain-api/cosmos/bank/v1beta1/spendable_balances/gonka1fixtureparticipant" ]] || return 91
    [[ "$GDC_TEST_MODE" != unavailable ]] || return 7
    case "$GDC_TEST_MODE" in
      zero) printf '%s\n' '{"balances":[{"denom":"ngonka","amount":"0"}]}' >"$output" ;;
      funded) printf '%s\n' '{"balances":[{"denom":"ngonka","amount":"100000000000"}]}' >"$output" ;;
      fee-spent) printf '%s\n' '{"balances":[{"denom":"ngonka","amount":"99999999999"}]}' >"$output" ;;
      malformed) printf '%s\n' '{"balances":"invalid"}' >"$output" ;;
      duplicate) printf '%s\n' '{"balances":[{"denom":"ngonka","amount":"1"},{"denom":"ngonka","amount":"2"}]}' >"$output" ;;
      *) return 92 ;;
    esac
    printf '200'
  }
  if [[ "$state" == should-fail ]]; then
    if ( ensure_membership_funding active gonka1fixtureparticipant ) >/dev/null 2>&1; then
      echo "membership funding unexpectedly accepted $mode" >&2
      exit 1
    fi
    [[ ! -s "$GDC_TEST_CLAIMS" ]] || { echo "membership funding claimed after $mode failure" >&2; exit 1; }
  else
    ensure_membership_funding "$state" gonka1fixtureparticipant >/dev/null
    if [[ "$expect_claim" == true ]]; then
      [[ "$(<"$GDC_TEST_CLAIMS")" == gonka1fixtureparticipant ]]
    else
      [[ ! -s "$GDC_TEST_CLAIMS" ]]
    fi
  fi
)

run_case active zero true
run_case active funded false
run_case active fee-spent false
run_case registered funded true
run_case should-fail unavailable false
run_case should-fail malformed false
run_case should-fail duplicate false
printf 'PASS membership resume funds active zero-balance accounts, preserves positive post-fee balances, and fails closed on unavailable or malformed bank data\n'
