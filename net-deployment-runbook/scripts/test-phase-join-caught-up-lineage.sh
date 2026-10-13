#!/usr/bin/env bash
# Exercise the actual post-canary verifier invocation without a Host. A
# canary that is caught up has its own current-checkpoint proof; the original
# receipt's TTL must not be reapplied at this boundary.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

remote="$tmp/remote"
mkdir -p "$remote"
cat >"$remote/verify-join-lineage-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == http://127.0.0.1:26657 ]]
[[ "$2" == "$GDC_TEST_REMOTE/lineage-receipt.json" ]]
[[ "$3" == --resume-current ]]
touch "$GDC_TEST_CALLED"
EOF
chmod 0755 "$remote/verify-join-lineage-state.sh"

run_verifier() (
  export NODE=fixture REMOTE="$remote" GDC_TEST_REMOTE="$remote" GDC_TEST_CALLED="$tmp/called"
  join_canary_transport_step() {
    [[ "$1" == canary_verify && "$2" == canary_verified ]]
    shift 2
    "$@"
  }
  ssh() {
    [[ "$1" == fixture ]]
    shift
    bash -c "$1"
  }
  eval "$(sed -n '/^verify_caught_up_canary_lineage() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh")"
  verify_caught_up_canary_lineage
)

run_verifier
[[ -f "$tmp/called" ]] || { echo 'caught-up canary did not run the current-checkpoint verifier' >&2; exit 1; }

# The control runs the same lifecycle boundary with the current-checkpoint
# marker removed. The remote verifier makes the old TTL-rechecking call fail.
if (
  export NODE=fixture REMOTE="$remote" GDC_TEST_REMOTE="$remote" GDC_TEST_CALLED="$tmp/control-called"
  join_canary_transport_step() { [[ "$1" == canary_verify && "$2" == canary_verified ]]; shift 2; "$@"; }
  ssh() { [[ "$1" == fixture ]]; shift; bash -c "$1"; }
  eval "$(sed -n '/^verify_caught_up_canary_lineage() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh" | sed 's/ --resume-current//')"
  verify_caught_up_canary_lineage
) >/dev/null 2>&1; then
  echo 'expired consumed receipt control unexpectedly passed' >&2
  exit 1
fi
[[ ! -e "$tmp/control-called" ]] || { echo 'expired consumed receipt control reached the verifier' >&2; exit 1; }

printf 'PASS caught-up signerless canary uses current-checkpoint lineage verification\n'
