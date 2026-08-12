#!/usr/bin/env bash
set -Eeuo pipefail

# Test-only replacement for scripts/inferenced.sh. It models the small keyring
# contract required by create-cold-accounts.sh without a real chain binary.
[[ "$1" == keys ]] || { echo "unexpected command: $*" >&2; exit 2; }
action="$2"
name="$3"
state_dir="$GDC_HOME/stub-keyring"
marker="$state_dir/$name"
address='gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
pubkey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
mkdir -p "$state_dir"

case "$action" in
  add)
    : >"$marker"
    printf '%s\n' 'one one one one one one one one one one one one one one one one one one one one one one one one'
    ;;
  show)
    [[ -e "$marker" ]] || exit 1
    if [[ " $* " == *' --pubkey '* ]]; then
      printf '{"key":"%s"}\n' "$pubkey"
    else
      printf '%s\n' "$address"
    fi
    ;;
  *)
    echo "unexpected key action: $action" >&2
    exit 2
    ;;
esac
