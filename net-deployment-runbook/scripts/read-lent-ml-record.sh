#!/usr/bin/env bash
# Read the donor-owned lending record without inferring a parent from aliases.
# Exit 10 means the record is confirmed absent; 195 means that absence cannot
# be proved safely because the Host or record could not be read.
set -Eeuo pipefail

parent_only=false
case "${1:-}" in
  --parent) parent_only=true; shift ;;
esac
NODE="${1:-}"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$#" == 1 ]] || {
  echo 'Usage: read-lent-ml-record.sh [--parent] SSH_ALIAS' >&2
  exit 2
}

if record="$(ssh -T "$NODE" 'sudo -n bash -s -- gdc-lent-ml-record' <<'REMOTE'
set -Eeuo pipefail
[[ "$1" == gdc-lent-ml-record ]]
record=/srv/dai/deploy/.node-control/lent-ml.json
[[ ! -e "$record" && ! -L "$record" ]] && exit 0
[[ -f "$record" && ! -L "$record" ]] || exit 2
cat "$record"
REMOTE
)"; then
  :
else
  printf 'OPERATOR ACTION REQUIRED cannot read the retained ML lending record for %s; leave the donor stopped and restore SSH access before rerunning gdc host start %s\n' "$NODE" "$NODE" >&2
  exit 195
fi
[[ -n "$record" ]] || exit 10

if ! jq -e --arg donor "$NODE" '
  select(.schema_version == 1 and .kind == "gdc-lent-validator-ml" and
  (.parent_alias | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and .parent_alias != $donor and
  (.endpoint | test("^[A-Za-z0-9.-]+$")) and
  (.node_id | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$")))
' <<<"$record" >/dev/null; then
  printf 'OPERATOR ACTION REQUIRED cannot validate the retained ML lending record for %s; leave the donor stopped and repair the record before rerunning gdc host start %s\n' "$NODE" "$NODE" >&2
  exit 195
fi

if [[ "$parent_only" == true ]]; then
  jq -r .parent_alias <<<"$record"
else
  jq -c . <<<"$record"
fi
