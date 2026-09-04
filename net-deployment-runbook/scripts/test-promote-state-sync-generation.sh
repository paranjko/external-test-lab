#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/gdc-promotion-test.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
node=node9
data="$tmp/data"
deploy="$tmp/deploy/$node"
mkdir -p "$data/${node}.generations/old/inference" "$data/${node}.generations/new/inference" "$deploy" "$tmp/bin"
touch "$deploy/compose.yaml"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ " $* " == *' ps -q node '* ]] || exit 2
EOF
chmod 0755 "$tmp/bin/docker"

promote() {
  PATH="$tmp/bin:$PATH" GDC_PROMOTION_TEST_MODE=true GDC_PROMOTION_TEST_ROOT="$tmp" \
    "$ROOT/02-node/promote-state-sync-generation.sh" "$node" "$1" "$data/$node"
}

new="$data/${node}.generations/new"
printf 'DATA_DIR=%s\n' "$new" >"$deploy/.env"
promote "$new" >"$tmp/first.out"
[[ -L "$data/$node" && "$(readlink "$data/$node")" == "$new" ]]
grep -qx "DATA_DIR=$data/$node" "$deploy/.env"
jq -e '.state == "PROMOTED" and .generation == $generation' --arg generation "$new" "$deploy/.promotion-receipt.json" >/dev/null
promote "$new" >"$tmp/repeat.out"
grep -Fq 'already promoted' "$tmp/repeat.out"

next="$data/${node}.generations/next"
mkdir -p "$next/inference"
printf 'DATA_DIR=%s\n' "$next" >"$deploy/.env"
ln -s "$next" "$data/$node.next"
jq -cn --arg node "$node" --arg generation "$next" --arg previous "$new" --arg active_next "$data/$node.next" \
  '{schema_version:1,kind:"gdc-state-sync-promotion",state:"PROMOTING",node_name:$node,generation:$generation,previous_active:$previous,active_next:$active_next,recorded_at:"2026-09-02T00:00:00Z"}' >"$deploy/.promotion-receipt.json"
promote "$next" >"$tmp/recover.out"
[[ -L "$data/$node" && "$(readlink "$data/$node")" == "$next" ]]
jq -e '.state == "PROMOTED"' "$deploy/.promotion-receipt.json" >/dev/null

third="$data/${node}.generations/third"
mkdir -p "$third/inference"
printf 'DATA_DIR=%s\n' "$third" >"$deploy/.env"
ln -sfn "$new" "$data/$node"
jq -cn --arg node "$node" --arg generation "$third" --arg previous "$next" --arg active_next "$data/$node.next" \
  '{schema_version:1,kind:"gdc-state-sync-promotion",state:"PROMOTING",node_name:$node,generation:$generation,previous_active:$previous,active_next:$active_next,recorded_at:"2026-09-02T00:00:00Z"}' >"$deploy/.promotion-receipt.json"
if promote "$third" >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  echo 'foreign active pointer unexpectedly resumed a promotion' >&2; exit 1
fi
grep -Fq 'active pointer changed outside the recorded promotion' "$tmp/conflict.err"

rm -f "$data/$node" "$deploy/.promotion-receipt.json"
mkdir "$data/$node"
printf 'DATA_DIR=%s\n' "$third" >"$deploy/.env"
if promote "$third" >"$tmp/legacy.out" 2>"$tmp/legacy.err"; then
  echo 'legacy data directory unexpectedly entered pointer promotion' >&2; exit 1
fi
grep -Fq 'canonical data path is a legacy directory' "$tmp/legacy.err"
printf 'PASS state-sync promotion is journaled, resumable and refuses pointer ambiguity\n'
