#!/usr/bin/env bash
# Verify the retained, receipt-bound JOIN state before a normal node restart
# re-enables the consensus signer.
set -Eeuo pipefail

usage() { echo "Usage: $0 --node NODE --run-dir DIR" >&2; }
node=''; run_dir=''
while (($#)); do
  case "$1" in
    --node) (($# >= 2)) || { usage; exit 2; }; shift; node="$1"; shift ;;
    --run-dir) (($# >= 2)) || { usage; exit 2; }; shift; run_dir="$1"; shift ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && -n "$run_dir" && -d "$run_dir" && ! -L "$run_dir" ]] \
  || { usage; exit 2; }
profile="$run_dir/join-profile.v1.json"
result="$run_dir/join-result.v1.json"
receipts="$run_dir/receipts"
for file in "$profile" "$result"; do
  [[ -f "$file" && ! -L "$file" && "$(stat -c %a "$file")" == 600 ]] \
    || { echo "completed JOIN signer authorization missing safe input=$(basename "$file")" >&2; exit 1; }
done
[[ -d "$receipts" && ! -L "$receipts" ]] \
  || { echo 'completed JOIN signer authorization missing receipt chain' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Expiry is irrelevant after mutation. The profile itself remains bound by its
# profile_id and the receipt chain below binds that exact profile hash.
"$ROOT/scripts/join-profile.sh" validate --allow-expired "$profile" >/dev/null \
  || { echo 'completed JOIN signer authorization has an invalid immutable profile' >&2; exit 1; }
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
profile_node="$(jq -er '.spec.target.node_name' "$profile")"
[[ "$profile_node" == "$node" ]] \
  || { echo "completed JOIN signer authorization targets another node: $profile_node" >&2; exit 1; }
chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")" \
  || { echo 'completed JOIN signer authorization has an invalid receipt chain' >&2; exit 1; }
[[ "$(jq -r .last_state <<<"$chain")" == COMPLETE && "$(jq -r .signer_ever_started <<<"$chain")" == true ]] \
  || { echo 'completed JOIN signer authorization requires COMPLETE receipt with signer_ever_started=true' >&2; exit 1; }
terminal_profile_sha256="$(jq -r '.join_profile_sha256 // empty' "$result")"
[[ "$(jq -r .outcome "$result")" == succeeded && "$terminal_profile_sha256" == "$profile_sha256" ]] \
  || { echo 'completed JOIN signer authorization is not bound to the successful completed profile' >&2; exit 1; }
printf 'PASS completed JOIN signer state verified node=%s profile_sha256=%s\n' "$node" "$profile_sha256"
