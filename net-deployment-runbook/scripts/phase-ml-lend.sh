#!/usr/bin/env bash
# Lend the already installed local ML runtime of a stopped validator. This is
# deliberately separate from phase-ml-add's clean ML-only provisioning path.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

PARENT="${1:-}"
ENDPOINT="${2:-}"
DONOR="${3:-}"
topology_contains_node "$PARENT" || die "ml lend expects an alias from GDC_NODE_ALIASES, got: $PARENT"
[[ "$DONOR" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$DONOR" != "$PARENT" ]] \
  || die 'ml lend requires a distinct validator SSH alias'
if ! "$ROOT/scripts/check-running-network-node.sh" "$PARENT"; then
  printf 'OPERATOR ACTION REQUIRED %s is not a running Network Node with a deployed DAPI endpoint; start or join it before lending a GPU\n' "$PARENT" >&2
  exit 195
fi

# Discovery is limited to the HostName declared for this SSH alias. It neither
# guesses from an alias nor silently converts a public address into an ML
# address. The parent-to-donor request below is the actual reachability proof.
if [[ -z "$ENDPOINT" ]]; then
  ENDPOINT="$(ssh -G "$DONOR" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
  [[ "$ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] \
    || die "cannot determine an unambiguous ML endpoint from SSH alias $DONOR; pass --mlnode-peer"
fi
[[ "$ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] \
  || die 'ml lend requires --mlnode-peer with an IPv4 address or DNS name'

# The parent must at least resolve the selected endpoint before the donor is
# stopped. The ML port is deliberately private while the validator owns it, so
# its actual /v1/models request is verified after the controlled lend exposes
# that port and before the parent configuration is changed.
parent_endpoint_ip="$(ssh -T "$PARENT" "getent ahostsv4 '$ENDPOINT' | awk 'NR == 1 {print \$1}'" 2>/dev/null || true)"
[[ "$parent_endpoint_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || {
    printf 'OPERATOR ACTION REQUIRED %s cannot resolve ML endpoint %s; provide a parent-reachable --mlnode-peer before lending the donor GPU\n' "$PARENT" "$ENDPOINT" >&2
    exit 195
  }

# Do this before stopping anything. A clean ML-only Host remains owned by the
# original provisioning flow; an installed validator is the only eligible
# donor for this non-destructive path.
donor_validation_rc=0
ssh -T "$DONOR" 'set -Eeuo pipefail
  sudo test -s /srv/dai/identity/p2p/node_key.json
  sudo test -d /srv/dai/signer/tmkms
  sudo test ! -L /srv/dai/signer/tmkms' \
  || donor_validation_rc=$?
case "$donor_validation_rc" in
  0) ;;
  255)
    printf 'OPERATOR ACTION REQUIRED %s is unreachable; restore SSH access and retry\n' "$DONOR" >&2
    exit 195
    ;;
  *)
    printf 'OPERATOR ACTION REQUIRED %s is not an installed validator with a local ML runtime; join or restore it before lending its GPU\n' "$DONOR" >&2
    exit 195
    ;;
esac

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/ml-lend-$PARENT-$DONOR"
mkdir -p "$RUN"
chmod 0700 "$RUN"
current_config="$RUN/node-config.before.json"
ssh -T "$PARENT" 'sudo cat /srv/dai/deploy/node-config.json' >"$current_config"
jq -e 'type == "array" and length > 0' "$current_config" >/dev/null \
  || die "$PARENT has no usable deployed ML endpoint configuration"

# A lent validator keeps its installed ML runtime and therefore must use the
# runtime that was actually rendered on that Host.  Do not substitute the
# caller's release profile: a restored JOIN can legitimately have another
# generated profile.  The configured local model is the bounded source of the
# startup arguments.
donor_runtime="$RUN/donor-local-ml-runtime.tsv"
ssh -T "$DONOR" 'sudo cat /srv/dai/deploy/node-config.json' >"$donor_runtime.json"
jq -er '
  def option($flag):
    (.args | indices($flag)) as $matches
    | if ($matches | length) != 1 then error("missing or duplicate " + $flag)
      else ($matches[0] + 1) as $index
        | if $index >= (.args | length) or (.args[$index] | type) != "string"
          then error("invalid value for " + $flag)
          else .args[$index]
          end
      end;
  [ .[]
    | select(.host == "inference")
    | .models
    | to_entries[]
    | {model: .key, args: .value.args}
  ] as $models
  | if ($models | length) != 1 then error("expected exactly one local model") else $models[0] end
  | [ .model, option("--revision"), option("--dtype"),
      option("--tensor-parallel-size"), option("--max-num-seqs"),
      option("--gpu-memory-utilization"), option("--max-model-len") ]
  | @tsv
' "$donor_runtime.json" >"$donor_runtime" \
  || die "$DONOR has no unambiguous local ML runtime configuration"
IFS=$'\t' read -r DONOR_MODEL DONOR_REVISION DONOR_DTYPE DONOR_TENSOR DONOR_MAX_SEQS DONOR_GPU_UTILIZATION DONOR_CONTEXT_LENGTH <"$donor_runtime"

start_donor_backend() {
  step "Start $DONOR local ML backend before lending it to $PARENT"
  "$ROOT/03-join/start-local-ml.sh" "$DONOR" "$DONOR_MODEL" "$DONOR_REVISION" \
    "$DONOR_DTYPE" "$DONOR_TENSOR" "$DONOR_MAX_SEQS" "$DONOR_GPU_UTILIZATION" "$DONOR_CONTEXT_LENGTH"
}

donor_record="$RUN/donor-lent-ml.json"
record_rc=0
ssh -T "$DONOR" 'set -Eeuo pipefail
  record=/srv/dai/deploy/.node-control/lent-ml.json
  sudo test ! -L "$record" || exit 11
  if ! sudo test -e "$record"; then
    exit 10
  fi
  sudo test -f "$record" || exit 11
  sudo cat "$record"' >"$donor_record" || record_rc=$?
case "$record_rc" in
  0) ;;
  10) : >"$donor_record" ;;
  *)
    printf 'OPERATOR ACTION REQUIRED cannot determine whether %s is already lent; leave it unchanged and restore SSH access before retrying\n' "$DONOR" >&2
    exit 195
    ;;
esac
if [[ -s "$donor_record" ]]; then
  if ! jq -e '
    .schema_version == 1 and .kind == "gdc-lent-validator-ml" and
    (.parent_alias | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.endpoint | test("^[A-Za-z0-9.-]+$")) and
    (.node_id | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))
  ' "$donor_record" >/dev/null 2>&1; then
    printf 'OPERATOR ACTION REQUIRED cannot determine whether %s is already lent; leave it unchanged and repair its retained lending record before retrying\n' "$DONOR" >&2
    exit 195
  fi
  recorded_parent="$(jq -r .parent_alias "$donor_record")"
  recorded_endpoint="$(jq -r .endpoint "$donor_record")"
  recorded_node_id="$(jq -r .node_id "$donor_record")"
  if [[ "$recorded_parent" != "$PARENT" ]]; then
    printf 'OPERATOR ACTION REQUIRED %s is already lent to %s; run gdc host start %s before lending it elsewhere\n' "$DONOR" "$recorded_parent" "$DONOR" >&2
    exit 195
  fi
  if [[ "$recorded_endpoint" != "$ENDPOINT" ]]; then
    printf 'OPERATOR ACTION REQUIRED %s is already lent to %s with a different ML endpoint; run gdc host start %s before changing the endpoint\n' "$DONOR" "$PARENT" "$DONOR" >&2
    exit 195
  fi
  jq -e --arg id "$recorded_node_id" --arg host "$ENDPOINT" 'any(.[]; .id == $id and .host == $host)' "$current_config" >/dev/null \
    || {
      printf 'OPERATOR ACTION REQUIRED cannot verify the retained ML endpoint for %s on %s; leave the donor stopped and inspect the parent before retrying\n' "$DONOR" "$PARENT" >&2
      exit 195
    }
  start_donor_backend
  ssh -T "$PARENT" "curl -fsS --connect-timeout 5 --max-time 15 'http://$ENDPOINT:5000/v1/models' | jq -e '.data | type == \"array\"' >/dev/null" \
    || die "$DONOR remains lent but $PARENT cannot reach its ML endpoint; the donor stays stopped for inspection"
  printf 'PASS %s already uses the retained ML runtime of %s\n' "$PARENT" "$DONOR"
  exit 0
fi

next_config="$RUN/node-config.next.json"
node_id_file="$RUN/external-node-id"
"$ROOT/scripts/add-network-ml-endpoint.sh" \
  --input "$current_config" --ml-host "$ENDPOINT" --ml-alias "$DONOR" \
  --output "$next_config" --id-output "$node_id_file"
EXTERNAL_NODE_ID="$(<"$node_id_file")"

step "Stop $DONOR validator and lend its existing ML runtime to $PARENT"
# `lend` owns both the pre-stop ML-runtime proof and the controlled stop.  Do
# not split that decision across two remote lifecycle actions: a donor without
# a usable local ML runtime must remain running.
bash "$ROOT/scripts/node-container-control.sh" lend "$DONOR" "$PARENT" "$ENDPOINT" "$EXTERNAL_NODE_ID"

# Compose being up proves only that the ML control plane is reachable.  The
# model backend is started separately and must be ready before DAPI is told
# about this endpoint.
start_donor_backend

# This request is made from the parent, rather than from the operator or the
# donor. It proves the actual route that DAPI will use before parent config is
# changed. Failure leaves the donor stopped and unregistered with the parent.
ssh -T "$PARENT" "curl -fsS --connect-timeout 5 --max-time 15 'http://$ENDPOINT:5000/v1/models' | jq -e '.data | type == \"array\"' >/dev/null" \
  || die "$PARENT cannot reach the lent ML endpoint on $DONOR; the donor remains stopped and no parent endpoint was added"

step "Add the lent ML endpoint from $DONOR to $PARENT"
remote_dir="/tmp/gdc-ml-lend-${GDC_RUN_ID:-manual}-$PARENT-$DONOR"
remote_config="$remote_dir/node-config.json"
remote_sync="$remote_dir/sync-node-config.sh"
ssh -T "$PARENT" "rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
scp -q "$next_config" "$PARENT:$remote_config"
scp -q "$ROOT/02-node/sync-node-config.sh" "$PARENT:$remote_sync"
if ! ssh -T "$PARENT" "set -Eeuo pipefail
  sudo install -m 0644 '$remote_config' '/srv/dai/deploy/node-config.json.tmp'
  sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json'
  sudo bash '$remote_sync'
  rm -rf '$remote_dir'"; then
  scp -q "$current_config" "$PARENT:$remote_config"
  ssh -T "$PARENT" "sudo install -m 0644 '$remote_config' '/srv/dai/deploy/node-config.json.tmp' && sudo mv '/srv/dai/deploy/node-config.json.tmp' '/srv/dai/deploy/node-config.json' && sudo bash '$remote_sync' && rm -rf '$remote_dir'" || true
  die "$PARENT did not accept the lent ML endpoint; its prior configuration was restored and $DONOR remains stopped"
fi

api_nodes="$RUN/dapi-nodes.json"
ssh -T "$PARENT" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes' >"$api_nodes"
jq -e --arg id "$EXTERNAL_NODE_ID" --arg host "$ENDPOINT" '
  type == "array" and any(.[]; .node.id == $id and .node.host == $host and .node.inference_port == 5000 and .node.poc_port == 5000)
' "$api_nodes" >/dev/null || die "$PARENT DAPI did not retain the lent ML endpoint after synchronization"

# The donor record is authority for return. The parent deployment record and
# both operator files are caches/readback aids; losing them must not cause the
# donor to guess a parent when it is started. Preserve every other configured
# ML endpoint on the parent while adding this one.
existing_link="$(ssh -T "$PARENT" 'sudo cat /srv/dai/deploy/gdc-ml-link.json 2>/dev/null' || true)"
if jq -e --arg parent "$PARENT" '.schema_version == 2 and .validator_alias == $parent and (.ml_hosts | type == "array")' \
  <<<"$existing_link" >/dev/null 2>&1; then
  link_record="$(jq -c --arg donor "$DONOR" --arg endpoint "$ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
    '.ml_hosts += [{ssh_alias:$donor,endpoint:$endpoint,node_id:$node_id,ownership:"lent_validator"}]' <<<"$existing_link")"
elif jq -e --arg parent "$PARENT" '.schema_version == 1 and .validator_alias == $parent' \
  <<<"$existing_link" >/dev/null 2>&1; then
  legacy_endpoint="$(jq -r .ml_endpoint <<<"$existing_link")"
  legacy_node_id="$(jq -er --arg endpoint "$legacy_endpoint" '.[] | select(.host == $endpoint) | .id' "$current_config")" \
    || die "legacy ML link for $PARENT does not match its deployed node configuration"
  link_record="$(jq -cn --arg parent "$PARENT" --arg alias "$(jq -r .ml_ssh_alias <<<"$existing_link")" \
    --arg endpoint "$legacy_endpoint" --arg legacy_node_id "$legacy_node_id" --arg donor "$DONOR" \
    --arg lent_endpoint "$ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
    '{schema_version:2,validator_alias:$parent,ml_hosts:[{ssh_alias:$alias,endpoint:$endpoint,node_id:$legacy_node_id},{ssh_alias:$donor,endpoint:$lent_endpoint,node_id:$node_id,ownership:"lent_validator"}]}')"
else
  link_record="$(jq -cn --arg parent "$PARENT" --arg donor "$DONOR" --arg endpoint "$ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
    '{schema_version:2,validator_alias:$parent,ml_hosts:[{ssh_alias:$donor,endpoint:$endpoint,node_id:$node_id,ownership:"lent_validator"}]}')"
fi
printf '%s\n' "$link_record" | ssh -T "$PARENT" 'set -Eeuo pipefail
  install_path=/srv/dai/deploy/gdc-ml-link.json
  sudo install -d -m 0750 /srv/dai/deploy
  sudo tee "${install_path}.tmp" >/dev/null
  sudo install -m 0640 "${install_path}.tmp" "$install_path"
  sudo rm -f "${install_path}.tmp"'
install -d -m 0700 "$STATE/ml-attached"
printf '%s\n' "$link_record" >"$STATE/ml-attached/$PARENT.json"
chmod 0600 "$STATE/ml-attached/$PARENT.json"
install -d -m 0700 "$GDC_DATA_ROOT/$DONOR/state"
donor_parent_record="$(jq -cn --arg parent "$PARENT" --arg donor "$DONOR" --arg endpoint "$ENDPOINT" --arg node_id "$EXTERNAL_NODE_ID" \
  '{schema_version:1,kind:"gdc-ml-parent",network_alias:$parent,ml_alias:$donor,endpoint:$endpoint,node_id:$node_id}')"
printf '%s\n' "$donor_parent_record" >"$GDC_DATA_ROOT/$DONOR/state/ml-parent.json"
chmod 0600 "$GDC_DATA_ROOT/$DONOR/state/ml-parent.json"
printf 'READY %s uses the stopped validator ML runtime of %s; run gdc host start %s to reclaim it\n' "$PARENT" "$DONOR" "$DONOR"
