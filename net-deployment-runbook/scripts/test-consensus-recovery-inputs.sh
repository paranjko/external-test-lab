#!/usr/bin/env bash
# Namespace construction; archive cryptography is covered separately.
set -Eeuo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
sha() { sha256sum "$1" | awk '{print $1}'; }
fixture() {
  base="$temp/$1"; scripts="$base/scripts"; parent="$base/parent"; output="$base/recovery"
  export GDC_HOME="$base/home" ARCHIVE_VALID=yes
  mkdir -p "$scripts" "$parent/receipts" "$GDC_HOME/genesis"
  cp "$source_dir/prepare-consensus-recovery-inputs.sh" "$source_dir/record-join-receipt.sh" "$scripts/"
  chmod +x "$scripts/record-join-receipt.sh"
  cat >"$scripts/validator-backup.sh" <<'STUB'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
genesis_sha256() { printf normalized-genesis; }
verify_backup_archive() { [[ ${ARCHIVE_VALID:-yes} == yes ]]; }
safe_extract() {
  mkdir -p "$2/remote-state/tmkms/state"
  printf '%s' '{"identity":{"consensus_pubkey":"archive-key"}}' >"$2/manifest.json"
  printf '%s' '{"height":"20","round":"0","step":2,"block_id":null}' >"$2/remote-state/tmkms/state/priv_validator_state.json"
}
STUB
  for name in verify-join-resume-inputs.sh join-profile.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$scripts/$name"
    chmod +x "$scripts/$name"
  done
  printf '%s' '{"chain_id":"test"}' >"$GDC_HOME/genesis/genesis.json"
  jq -n --arg genesis "$(sha "$GDC_HOME/genesis/genesis.json")" \
    '{run_id:"parent",created_at:"old",valid_until:"expired",spec:{network:{chain_id:"test",genesis_sha256:$genesis},identity:{mode:"generate"}}}' >"$parent/join-profile.v1.json"
  printf '%s' '{"observed_at":"old"}' >"$parent/network-observation.v1.json"
  jq -n --arg profile "$(sha "$parent/join-profile.v1.json")" --arg observation "$(sha "$parent/network-observation.v1.json")" \
    '{schema_version:2,kind:"gdc-host-join-receipt",run_id:"parent",operation:"new",node_name:"node5",state:"COMPLETE",
      generation_id:"generation",signer_ever_started:true,identity_fingerprints:{consensus_pubkey:"previous-key",
      p2p_node_id:("a"*40),participant_address:"account",warm_address:"preserved-warm"},
      tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"succeeded",resume_policy:"not_applicable",
      join_profile_sha256:$profile,network_observation_sha256:$observation}' >"$parent/receipts/0026-complete.json"
  printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' '\''{"last_state":"COMPLETE","signer_ever_started":true,"head_sha256":"%s"}'\''\n' \
    "$(sha "$parent/receipts/0026-complete.json")" >"$scripts/verify-join-receipt-chain.sh"
  chmod +x "$scripts/verify-join-receipt-chain.sh"
  printf synthetic-archive >"$base/backup.tar"
}
construct() { bash "$scripts/prepare-consensus-recovery-inputs.sh" node5 "$parent" "$base/backup.tar" "${1:-new}" "$output" node5.example; }
refuse() { if construct "$@" >"$base/result.log" 2>&1; then echo 'unexpected constructor success' >&2; exit 1; fi; }
fixture success
cp -a "$parent" "$base/parent-before"
construct
jq -e --arg sha "$(sha "$base/backup.tar")" '.run_id == "new" and .operation == "restore" and .valid_until == "expired" and .spec.identity.restore_archive_sha256 == $sha' "$output/join-profile.v1.json" >/dev/null
jq -e '.identity_fingerprints.consensus_pubkey == "archive-key" and .identity_fingerprints.warm_address == "preserved-warm" and .tmkms_state.height == 20 and .state == "RUN_CREATED" and .run_id == "new"' "$output/receipts/0001-run_created.json" >/dev/null
for file in join-profile.v1.json network-observation.v1.json receipts/0026-complete.json; do cmp "$parent/$file" "$base/parent-before/$file"; done
refuse
fixture parent-reuse
refuse parent
[[ ! -e "$output" ]]
fixture profile-changed
printf '\n' >>"$parent/join-profile.v1.json"
refuse
[[ ! -e "$output/recovery-parent.json" ]]
fixture observation-changed
printf '{}' >"$parent/network-observation.v1.json"
refuse
[[ ! -e "$output/recovery-parent.json" ]]
fixture bad-archive
export ARCHIVE_VALID=no
refuse
[[ ! -e "$output/recovery-parent.json" ]]
echo 'PASS recovery input isolation and refusal cases'
