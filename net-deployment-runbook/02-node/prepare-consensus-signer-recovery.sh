#!/usr/bin/env bash
# Freeze only the local consensus processes and retain their complete recovery
# material. This command does not replace keys, start services or grant authority
# to use an archived signer. Its caller must verify the recovery intent first.
prepare_consensus_signer_recovery() (
set -Eeuo pipefail
umask 077

[[ $# == 4 ]] || { echo "Usage: sudo $0 DEPLOY BACKUP_DIR RUN_ID EXPECTED_SOFTSIGN_SHA256" >&2; exit 2; }
deploy="$1"; backup_dir="$2"; run_id="$3"; expected_key_sha="$4"
[[ "$deploy" == /*/deploy && "$backup_dir" == /* && "$backup_dir" != / &&
   "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$expected_key_sha" =~ ^[a-f0-9]{64}$ ]] || {
  echo 'invalid consensus recovery preparation input' >&2; exit 2;
}
root="${deploy%/deploy}"
[[ -n "$root" && "$root" != / && -d "$root" && ! -L "$root" ]] || exit 2
[[ "$(readlink -m "$deploy")" == "$deploy" && "$(readlink -m "$backup_dir")" == "$backup_dir" ]] || {
  echo 'recovery paths must be canonical and contain no symlink parents' >&2; exit 2;
}
for path in "$deploy" "$root/signer" "$root/signer/tmkms" "$root/identity"; do
  [[ -d "$path" && ! -L "$path" ]] || { echo 'recovery directory is missing or unsafe' >&2; exit 1; }
done
for path in "$deploy/.env" "$deploy/compose.yaml" \
  "$root/signer/tmkms/secrets/priv_validator_key.softsign" \
  "$root/signer/tmkms/state/priv_validator_state.json"; do
  [[ -f "$path" && ! -L "$path" ]] || { echo 'recovery material is missing or unsafe' >&2; exit 1; }
  [[ "$(readlink -f "$path")" == "$path" ]] || { echo 'recovery material has a symlink parent' >&2; exit 1; }
done
[[ "$(sha256sum "$root/signer/tmkms/secrets/priv_validator_key.softsign" | awk '{print $1}')" == "$expected_key_sha" ]] || {
  echo 'current signer key changed before recovery preparation' >&2; exit 1;
}
case "$backup_dir/" in "$root/"*) echo 'backup must be outside validator root' >&2; exit 2 ;; esac
[[ ! -L "$backup_dir" ]] || { echo 'unsafe backup directory' >&2; exit 1; }
install -d -m 0700 "$backup_dir"
destination="$backup_dir/consensus-recovery-$run_id"
# mkdir is also the exclusive operation claim. A retry must inspect its receipt;
# it must never overwrite the backup or infer that a partial preparation passed.
mkdir -m 0700 "$destination" || { echo 'recovery preparation already exists; inspect retained evidence' >&2; exit 1; }
compose=(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile signer)
ids="$("${compose[@]}" ps -aq node tmkms)"
[[ -n "$ids" ]] || { echo 'no consensus containers to fence' >&2; exit 1; }
mapfile -t containers <<<"$ids"
[[ ${#containers[@]} == 2 ]] || { echo 'expected exactly one Core and one signer container' >&2; exit 1; }
for id in "${containers[@]}"; do
  [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || { echo 'invalid consensus container identity' >&2; exit 1; }
done
# Store only selected public container properties, never Config.Env.
docker inspect "${containers[@]}" | jq '[.[] | {Id,Image,Name,
  restart_policy:.HostConfig.RestartPolicy,service:.Config.Labels["com.docker.compose.service"]}]' \
  >"$destination/containers.json"
jq -e 'length == 2 and ([.[].service] | sort) == ["node","tmkms"]' "$destination/containers.json" >/dev/null
docker update --restart=no "${containers[@]}" >/dev/null
"${compose[@]}" stop tmkms node
docker inspect "${containers[@]}" | jq -e 'all(.[]; .State.Running == false and .HostConfig.RestartPolicy.Name == "no")' >/dev/null || {
  echo 'consensus processes are not fenced' >&2; exit 1;
}
[[ "$(sha256sum "$root/signer/tmkms/secrets/priv_validator_key.softsign" | awk '{print $1}')" == "$expected_key_sha" ]] || {
  echo 'current signer key changed while fencing' >&2; exit 1;
}
# Do not dereference links: neither external key material nor caches belong in
# this archive. All required paths above were checked as regular files.
tar -C "$root" -cf "$destination/validator-before.tar" signer identity deploy
chmod 600 "$destination/validator-before.tar"
tar -tf "$destination/validator-before.tar" >/dev/null
sha256sum "$destination/validator-before.tar" >"$destination/validator-before.tar.sha256"
install -m 0600 "$root/signer/tmkms/state/priv_validator_state.json" "$destination/signing-state-before.json"
archive_sha="$(awk '{print $1}' "$destination/validator-before.tar.sha256")"
jq -cn --arg run "$run_id" --arg archive "$archive_sha" --arg key "$expected_key_sha" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:1,kind:"gdc-consensus-recovery-preparation",run_id:$run,
    observed_at:$at,previous_softsign_sha256:$key,archive_sha256:$archive,
    consensus_processes_stopped:true,restart_disabled:true,activation_authorized:false}' \
  >"$destination/prepared.json.tmp"
sync -f "$destination"
mv "$destination/prepared.json.tmp" "$destination/prepared.json"
sync -f "$destination"
printf 'PASS consensus recovery preparation retained at %s; signer remains stopped\n' "$destination"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $EUID == 0 ]] || { echo 'consensus recovery preparation requires root' >&2; exit 2; }
  prepare_consensus_signer_recovery "$@"
fi
