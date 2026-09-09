#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "$*" >&2; exit 1; }

# Contract: a JOIN role input qualifies under its resolved release; Genesis
# keeps the baseline gate in its own phase.
grep -Fq '[[ "${GDC_JOIN_ROLE_INPUT:-false}" == true ]] || assert_baseline_release' "$ROOT/scripts/phase-qualify-ml.sh"
grep -Fxq 'assert_baseline_release' "$ROOT/scripts/phase-genesis.sh"

# The first current, non-baseline core release profile.
release=''
for lock in "$ROOT"/profiles/releases/*.lock; do
  candidate="${lock##*/}"
  candidate="${candidate%.lock}"
  [[ "$candidate" == v2026.07.23 ]] && continue
  [[ -e "$ROOT/profiles/releases/$candidate.retired" ]] && continue
  grep -Fxq 'CANDIDATE_LAYER=devshard' "$lock" && continue
  release="$candidate"
  break
done
[[ -n "$release" ]] || fail 'no non-baseline core release profile found'

# ssh never reaches a host: the stub fails every connection attempt, so the
# qualification records SKIP for the alias instead of contacting anything.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 255\n' >"$tmp/bin/ssh"
chmod 0755 "$tmp/bin/ssh"

alias='qualify-test.invalid'
write_role() {
  cat >"$1" <<ROLE
GDC_NODE_ALIASES=$alias
GDC_NODE_PUBLIC_HOSTS=$alias=127.0.0.1
GDC_NODE_P2P_PORTS=$alias=5000
GDC_NODE_ML_HOSTS=
GDC_DEPLOYMENT_PROFILE=community-lab
ROLE
}
join_role="$tmp/join.env"
write_role "$join_role"
cat >>"$join_role" <<'ROLE'
GDC_JOIN_NETWORK_HOST=127.0.0.1
GDC_CHAIN_RPC_URL=http://127.0.0.1:26657/
SEED_API_URL=http://127.0.0.1:8000
SEED_NODE_RPC_URL=http://127.0.0.1:26657
GDC_JOIN_ROLE_INPUT=true
ROLE
genesis_role="$tmp/genesis.env"
write_role "$genesis_role"
cat >>"$genesis_role" <<ROLE
GDC_GENESIS_NODE=$alias
GDC_PUBLIC_EDGE_NODE=$alias
GDC_GATEWAY_NODE=$alias
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_GENESIS_ROLE_INPUT=true
ROLE

qualify() {
  env PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator-home" GDC_ENV="$1" \
    GDC_RELEASE_PROFILE="$release" GDC_QUALIFY_HOSTS="$alias" \
    "$ROOT/scripts/phase-qualify-ml.sh"
}

if output="$(qualify "$genesis_role" 2>&1)"; then
  fail "expected the baseline gate to reject $release for a Genesis role input"
fi
grep -Fq "baseline phases require v2026.07.23, got $release" <<<"$output" \
  || fail "unexpected Genesis role output: $output"

output="$(qualify "$join_role" 2>&1)" || fail "JOIN role qualification failed: $output"
if grep -Fq 'baseline phases require' <<<"$output"; then
  fail "JOIN role input still hit the baseline gate: $output"
fi
grep -Fq "SKIP  $alias unreachable; no ML qualification claim" <<<"$output" \
  || fail "JOIN role output lacks the SKIP record: $output"
grep -Fq 'PASS ML qualification evidence' <<<"$output" \
  || fail "JOIN role output lacks the PASS record: $output"
printf 'PASS JOIN qualifies its target under the resolved release profile\n'
