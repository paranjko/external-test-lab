#!/usr/bin/env bash
# Execute the common verifier-call boundary with an allowlisted substitute.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts"
cp "$ROOT/scripts/lib-post-sync-join.sh" "$kit/scripts/"
cat >"$kit/scripts/verify-post-sync-join-state.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >"$GDC_TEST_ARGUMENTS"
SH
chmod 0755 "$kit/scripts/verify-post-sync-join-state.sh"
ROOT="$kit"
# shellcheck source=/dev/null
source "$kit/scripts/lib-post-sync-join.sh"

GDC_TEST_ARGUMENTS="$tmp/arguments" ROOT="$kit" \
  bash -c 'source "$ROOT/scripts/lib-post-sync-join.sh"; join_verify_promoted_signerless_state fixture "$@"' bash \
  /run/fixture /run/profile /tmp/gdc-fixture gonka-devnet-community \
  0123456789abcdef0123456789abcdef01234567 0.2.15 \
  1111111111111111111111111111111111111111 0.2.15-post3 \
  2222222222222222222222222222222222222222

expected='--node fixture --run-dir /run/fixture --profile /run/profile --remote-dir /tmp/gdc-fixture --expected-chain-id gonka-devnet-community --expected-p2p-node-id 0123456789abcdef0123456789abcdef01234567 --expected-core-version 0.2.15 --expected-core-commit 1111111111111111111111111111111111111111 --expected-dapi-version 0.2.15-post3 --expected-dapi-commit 2222222222222222222222222222222222222222'
[[ "$(<"$tmp/arguments")" == "$expected" ]]
if ROOT="$kit" bash -c 'source "$ROOT/scripts/lib-post-sync-join.sh"; join_verify_promoted_signerless_state too few inputs' >/dev/null 2>&1; then
  echo 'post-sync verifier helper accepted an incomplete runtime binding' >&2
  exit 1
fi

auxiliary_events="$tmp/auxiliary-events"
start_stack() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >>"$auxiliary_events"; }
ROOT="$kit" join_start_verified_auxiliary_services fixture public-edge
[[ "$(<"$auxiliary_events")" == $'fixture|/srv/dai/deploy/edge|caddy\nfixture|/srv/dai/deploy/monitoring-agent|' ]]
: >"$auxiliary_events"
ROOT="$kit" join_start_verified_auxiliary_services public-edge public-edge >"$tmp/public-edge.out"
[[ "$(<"$auxiliary_events")" == 'public-edge|/srv/dai/deploy/monitoring-agent|' ]]
[[ "$(<"$tmp/public-edge.out")" == 'READY retained shared public edge on public-edge during participant JOIN' ]]
if ROOT="$kit" join_start_verified_auxiliary_services fixture >/dev/null 2>&1; then
  echo 'post-sync auxiliary helper accepted an incomplete binding' >&2
  exit 1
fi
printf 'PASS shared post-sync helper verifies the runtime then starts the correct auxiliary services\n'
