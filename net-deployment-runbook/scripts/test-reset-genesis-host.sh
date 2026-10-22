#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -e /.dockerenv && "${GDC_TEST_DISPOSABLE_ROOT:-false}" == true ]] \
  || { echo 'test-reset-genesis-host.sh requires the disposable test container' >&2; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' /srv
[[ "${GDC_TEST_EXTRA_MOUNT:-false}" != true ]] || printf '%s\n' /srv/dai/data/extra
MOCK
cat >"$fake_bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GDC_TEST_SYSTEMCTL_LOG:?}"
case "${1:-}" in
  disable) exit 0 ;;
  is-active) exit 1 ;;
  *) echo "unexpected systemctl invocation: $*" >&2; exit 34 ;;
esac
MOCK
cat >"$fake_bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
log="${GDC_TEST_DOCKER_LOG:?}"
case "${1:-}" in
  ps)
    if [[ -n "${GDC_TEST_LEGACY_LAYOUT:-}" ]]; then
      case "${GDC_TEST_LEGACY_LAYOUT}" in
        node2) layout_ids=$'legacy-router\nlegacy-mlnode' ;;
        node10) layout_ids='legacy-router' ;;
        node11) layout_ids='legacy-dual-router' ;;
        *) exit 37 ;;
      esac
      if [[ " $* " == *' -aq '* && "$*" == *--filter* ]]; then
        :
      elif [[ " $* " == *' -aq '* ]]; then
        printf '%s\n' "$layout_ids"
      else
        while IFS= read -r id; do
          [[ -n "$id" ]] || continue
          grep -Fq "stop $id" "$log" || printf '%s\n' "$id"
        done <<<"$layout_ids"
      fi
      exit 0
    fi
    if [[ "${GDC_TEST_NODE3_UNITS:-false}" == true ]]; then exit 0; fi
    if [[ "${GDC_TEST_ML_PROJECT:-false}" == true ]]; then
      if [[ " $* " == *' -aq '* && "$*" == *--filter* ]]; then
        [[ "$*" == *gdc-node4-ml* ]] && printf '%s\n' ml-container
      elif [[ " $* " == *' -aq '* ]]; then
        printf '%s\n' ml-container
      else
        grep -Fq 'stop ml-container' "$log" || printf '%s\n' ml-container
      fi
      exit 0
    fi
    if [[ " $* " == *' -aq '* ]]; then
      if [[ "$*" == *--filter* ]]; then
        case "$*" in
          *gdc-edge-gdc-node0*) printf '%s\n' edge-container ;;
          *gdc-monitoring-agent-gdc-node0*) : ;;
          *gdc-node0*) printf '%s\n' core-container ;;
          *) exit 31 ;;
        esac
      else
        printf '%s\n' core-container edge-container monitoring-container outsider
      fi
    else
      if [[ "${GDC_TEST_EXTERNAL_BIND:-false}" == true ]]; then
        printf '%s\n' outsider
      else
        printf '%s\n' outsider
      fi
      printf '%s\n' monitoring-container
      grep -Fq 'stop core-container' "$log" || printf '%s\n' core-container
      grep -Fq 'stop edge-container' "$log" || printf '%s\n' edge-container
    fi
    ;;
  inspect)
    if [[ -n "${GDC_TEST_LEGACY_LAYOUT:-}" ]]; then
      if [[ "${2:-}" == -f ]]; then
        case "${3:-}" in
          '{{.State.Status}}')
            grep -Fq "stop ${4:-}" "$log" && printf 'exited\n' || printf 'running\n' ;;
          '{{.HostConfig.RestartPolicy.Name}}')
            grep -Fq "restart-no ${4:-}" "$log" && printf 'no\n' || printf 'unless-stopped\n' ;;
          *) exit 35 ;;
        esac
        exit 0
      fi
      case "${2:-}" in
        legacy-router)
          source=/srv/dai/deploy/.three-model-layout-sidecar/nginx.conf
          [[ "${GDC_TEST_LEGACY_UNSAFE:-false}" != true ]] || source=/srv/dai/deploy/unexpected/nginx.conf
          if [[ "$GDC_TEST_LEGACY_LAYOUT" == node2 || "$GDC_TEST_LEGACY_LAYOUT" == node10 ]]; then
            network="gdc-${GDC_TEST_LEGACY_LAYOUT}_default"
            [[ "${GDC_TEST_LEGACY_UNSAFE_NETWORK:-false}" != true ]] || network=foreign_default
            image=sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609
            [[ "${GDC_TEST_LEGACY_UNSAFE_IMAGE:-false}" != true ]] || image=sha256:0000000000000000000000000000000000000000000000000000000000000000
            printf '[{"Name":"/gdc-layout06-router","Config":{"Image":"%s","Labels":{"gonka.layout":"three-models","maintainer":"NGINX Docker Maintainers <docker-maint@nginx.com>"}},"NetworkSettings":{"Networks":{"%s":{}}},"Mounts":[{"Source":"%s","Destination":"/etc/nginx/nginx.conf","RW":false}]}]\n' "$image" "$network" "$source"
          else exit 32; fi ;;
        legacy-mlnode)
          printf '%s\n' '[{"Name":"/gdc-layout06-mlnode","Config":{"Image":"sha256:1b9b7ce55feecab837f1d7ce974fc5f377ae0a04a4fb403eeeb50130e7728ee1","Labels":{"gonka.layout":"three-models","ai.vllm.build.commit":"752a3a504485790a2e8491cacbb35c137339ad34"}},"NetworkSettings":{"Networks":{"gdc-node2_default":{}}},"Mounts":[{"Source":"/srv/hf-cache/hub","Destination":"/root/.cache/hub","RW":false}]}]' ;;
        legacy-dual-router)
          printf '%s\n' '[{"Name":"/gdc-node11-dual-router4b-1","Config":{"Image":"nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609","Labels":{"com.docker.compose.project":"gdc-node11-dual","com.docker.compose.service":"router4b","com.docker.compose.project.config_files":"/srv/dai/deploy/model-layout-7b-4b/compose.yaml","com.docker.compose.project.working_dir":"/srv/dai/deploy/model-layout-7b-4b"}},"NetworkSettings":{"Networks":{"gdc-node11_default":{}}},"Mounts":[{"Source":"/srv/dai/deploy/model-layout-7b-4b/nginx.conf","Destination":"/etc/nginx/nginx.conf","RW":false}]}]' ;;
        *) exit 32 ;;
      esac
      exit 0
    fi
    if [[ "${2:-}" == -f ]]; then
      case "${3:-}" in
        '{{.State.Status}}')
          if grep -Fq "stop ${4:-}" "$log"; then printf 'exited\n'; else printf 'running\n'; fi ;;
        '{{.HostConfig.RestartPolicy.Name}}')
          if grep -Fq "restart-no ${4:-}" "$log"; then printf 'no\n'; else printf 'unless-stopped\n'; fi ;;
        *) exit 35 ;;
      esac
      exit 0
    fi
    case "${2:-}" in
      ml-container)
        printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"gdc-node4-ml"}},"Mounts":[{"Source":"/srv/dai/deploy/gdc-node4-ml"},{"Source":"/srv/dai/hf-cache"}]}]' ;;
      core-container)
        if [[ "${GDC_TEST_GENERATION_BIND:-false}" == true ]]; then
          printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"gdc-node0"}},"Mounts":[{"Source":"/srv/dai/data/inference"},{"Source":"/srv/dai/data/dapi"},{"Source":"/srv/dai/data.generations/generation-bound/api"},{"Source":"/srv/dai/deploy/node-config.json"},{"Source":"/srv/dai/identity"},{"Source":"/srv/dai/shared/genesis.json"},{"Source":"/srv/dai/signer/tmkms"},{"Source":"/srv/hf-cache"}]}]'
        else
          printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"gdc-node0"}},"Mounts":[{"Source":"/srv/dai/data/inference"},{"Source":"/srv/dai/data/dapi"},{"Source":"/srv/dai/deploy/node-config.json"},{"Source":"/srv/dai/identity"},{"Source":"/srv/dai/shared/genesis.json"},{"Source":"/srv/dai/signer/tmkms"},{"Source":"/srv/hf-cache"}]}]'
        fi ;;
      edge-container)
        printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"gdc-edge-gdc-node0"}},"Mounts":[{"Source":"/srv/dai/deploy/edge"},{"Source":"/srv/dai/edge/site"},{"Source":"/srv/dai/caddy/data"}]}]' ;;
      monitoring-container)
        printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"gdc-monitoring-agent"}},"Mounts":[{"Source":"/srv/dai/monitoring-agent"}]}]' ;;
      outsider)
        if [[ "${GDC_TEST_FOREIGN_GENERATION_BIND:-false}" == true ]]; then
          printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"broker-a"}},"Mounts":[{"Source":"/srv/dai/data.generations/generation-active/inference"}]}]'
        elif [[ "${GDC_TEST_EXTERNAL_BIND:-false}" == true ]]; then
          printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"broker-a"}},"Mounts":[{"Source":"/srv/dai/data/inference"}]}]'
        else
          printf '%s\n' '[{"State":{"Status":"running"},"Config":{"Labels":{"com.docker.compose.project":"broker-a"}},"Mounts":[{"Source":"/srv/broker"}]}]'
        fi ;;
      *) exit 32 ;;
    esac
    ;;
  stop) printf 'stop %s\n' "$2" >>"$log" ;;
  update)
    [[ "${2:-}" == --restart=no ]] || exit 36
    printf 'restart-no %s\n' "$3" >>"$log" ;;
  *) echo "unexpected docker invocation: $*" >&2; exit 33 ;;
esac
MOCK
chmod +x "$fake_bin/findmnt" "$fake_bin/systemctl" "$fake_bin/docker"

fixture_reset() {
  rm -rf -- /srv/dai /srv/dai-archives /srv/broker /srv/edge
  mkdir -p /srv/dai/deploy/edge /srv/dai/deploy/gdc-node0 /srv/dai/data/inference \
    /srv/dai/data/gdc-node0 \
    /srv/dai/data/dapi /srv/dai/gdc-node0 /srv/dai/identity /srv/dai/signer \
    /srv/dai/shared /srv/dai/ops /srv/dai/edge /srv/dai/broker-tests \
    /srv/dai/backups /srv/dai/recovery /srv/dai/caddy /srv/dai/monitoring-agent \
    /srv/dai/identity-bootstrap /srv/hf-cache /srv/broker /srv/edge/node0
  mkdir -p /srv/dai/deploy/gdc-node4-ml /srv/dai/hf-cache
  printf 'canonical\n' >/srv/dai/deploy/.env
  printf 'DATA_DIR=/srv/dai/data\nCOMPOSE_PROJECT_NAME=gdc-node0\n' >/srv/dai/deploy/.env
  printf 'DATA_DIR=/srv/dai/data/gdc-node0\n' >/srv/dai/deploy/gdc-node0/.env
  printf 'validator chain\n' >/srv/dai/data/inference/state
  printf 'legacy chain\n' >/srv/dai/gdc-node0/state
  printf 'nested legacy chain\n' >/srv/dai/data/gdc-node0/state
  printf 'deploy config\n' >/srv/dai/deploy/compose.yaml
  printf 'identity\n' >/srv/dai/identity/p2p-key
  printf 'signer\n' >/srv/dai/signer/key
  printf '{}\n' >/srv/dai/shared/genesis.json
  printf 'keep\n' >/srv/dai/ops/keep
  printf 'keep\n' >/srv/dai/edge/keep
  printf 'keep\n' >/srv/dai/broker-tests/keep
  printf 'keep\n' >/srv/hf-cache/keep
  printf 'keep\n' >/srv/dai/backups/keep
  printf 'keep\n' >/srv/dai/recovery/keep
  printf 'keep\n' >/srv/dai/caddy/keep
  printf 'keep\n' >/srv/dai/monitoring-agent/keep
  printf 'keep\n' >/srv/dai/identity-bootstrap/keep
  printf 'keep\n' >/srv/broker/keep
  printf 'keep\n' >/srv/edge/node0/keep
  : >"$tmp/docker.log"
  : >"$tmp/systemctl.log"
}
make_generation_layout() {
  local link_target="$1"
  rm -rf -- /srv/dai/data
  mkdir -p /srv/dai/data.generations/generation-active/inference \
    /srv/dai/data.generations/generation-bound/api /srv/dai/data.generations/generation-unbound
  printf 'active chain\n' >/srv/dai/data.generations/generation-active/inference/state
  printf 'bound dapi\n' >/srv/dai/data.generations/generation-bound/api/state
  ln -s -- "$link_target" /srv/dai/data
}

run_reset() {
  env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
    GDC_TEST_GENERATION_BIND="${GDC_TEST_GENERATION_BIND:-false}" \
    "$ROOT/scripts/reset-genesis-host.sh" gdc-node0 20261020T120000Z
}
run_ml_reset() {
  env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
    GDC_TEST_ML_PROJECT=true \
    "$ROOT/scripts/reset-genesis-host.sh" gdc-node9 20261020T120000Z --ml-project gdc-node4-ml
}
run_legacy_reset() {
  local legacy_host="$1" layout="$2"
  env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
    GDC_TEST_LEGACY_LAYOUT="$layout" \
    "$ROOT/scripts/reset-genesis-host.sh" "$legacy_host" 20261020T120000Z
}

fixture_reset
run_reset >"$tmp/success.out"
archive=/srv/dai-archives/20261020T120000Z-gdc-node0
grep -Fq "PASS new-Genesis Host reset host=gdc-node0 archive=$archive" "$tmp/success.out"
[[ -f "$archive/reset-genesis-intent.json" && -f "$archive/reset-genesis-receipt.json" ]]
[[ "$(stat -c '%a' "$archive/reset-genesis-receipt.json")" == 444 ]]
jq -e '.kind == "gdc-new-genesis-reset-receipt" and (.moved_paths | length) == 6 and (.systemd_units | length) == 6' "$archive/reset-genesis-receipt.json" >/dev/null
[[ -f "$archive/data/inference/state" && -f "$archive/data/gdc-node0/state" && -f "$archive/gdc-node0/state" ]]
for path in /srv/broker/keep /srv/edge/node0/keep /srv/dai/ops/keep /srv/dai/edge/keep \
  /srv/dai/broker-tests/keep /srv/hf-cache/keep /srv/dai/backups/keep \
  /srv/dai/recovery/keep /srv/dai/caddy/keep /srv/dai/monitoring-agent/keep \
  /srv/dai/identity-bootstrap/keep; do [[ -f "$path" ]]; done
grep -Fxq 'stop core-container' "$tmp/docker.log"
grep -Fxq 'stop edge-container' "$tmp/docker.log"
grep -Fxq 'restart-no core-container' "$tmp/docker.log"
grep -Fxq 'restart-no edge-container' "$tmp/docker.log"
if grep -Fq 'stop outsider' "$tmp/docker.log"; then exit 1; fi
if grep -Fq 'gdc-monitoring-agent' "$tmp/docker.log"; then exit 1; fi
grep -Fxq 'disable --now gdc-poc-winddown-watch@gdc-node0.service' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-version-collector@gdc-node0.timer' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-version-collector@gdc-node0.service' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-poc-winddown-watch@node0.service' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-version-collector@node0.timer' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-version-collector@node0.service' "$tmp/systemctl.log"
if grep -Fq 'gdc-node1' "$tmp/systemctl.log"; then exit 1; fi

# The actual short alias observed on Hosts is also stopped, while adjacent
# node instances remain untouched. Use an empty Docker fixture to isolate the
# systemd inventory for node3.
fixture_reset
env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
  GDC_TEST_NODE3_UNITS=true \
  "$ROOT/scripts/reset-genesis-host.sh" gdc-node3 20261020T120000Z >"$tmp/node3-units.out"
grep -Fxq 'disable --now gdc-poc-winddown-watch@gdc-node3.service' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-poc-winddown-watch@node3.service' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-version-collector@node3.timer' "$tmp/systemctl.log"
grep -Fxq 'disable --now gdc-version-collector@node3.service' "$tmp/systemctl.log"
if grep -Eq 'gdc-node[2458]|@(node[2458])\\.' "$tmp/systemctl.log"; then exit 1; fi
jq -e '[.systemd_units[].unit] | index("gdc-poc-winddown-watch@node3.service") != null and index("gdc-version-collector@node3.timer") != null' \
  /srv/dai-archives/20261020T120000Z-gdc-node3/reset-genesis-receipt.json >/dev/null

# ML-only reset of the attached node9 worker archives only the named ML
# Compose project root and leaves the validator's data, identity, signer and
# both HF cache roots untouched.
fixture_reset
printf 'ml project config\n' >/srv/dai/deploy/gdc-node4-ml/compose.yaml
printf 'validator state remains\n' >/srv/dai/data/inference/state
printf 'validator identity remains\n' >/srv/dai/identity/p2p-key
printf 'validator signer remains\n' >/srv/dai/signer/key
printf 'cache remains\n' >/srv/dai/hf-cache/keep
run_ml_reset >"$tmp/ml-reset.out"
ml_archive=/srv/dai-archives/20261020T120000Z-gdc-node9
[[ -f "$ml_archive/deploy/gdc-node4-ml/compose.yaml" ]]
[[ -f /srv/dai/data/inference/state && -f /srv/dai/identity/p2p-key && -f /srv/dai/signer/key ]]
[[ -f /srv/dai/hf-cache/keep && -f /srv/hf-cache/keep ]]
[[ ! -e /srv/dai/deploy/gdc-node4-ml ]]
grep -Fxq 'stop ml-container' "$tmp/docker.log"
grep -Fxq 'restart-no ml-container' "$tmp/docker.log"
grep -Fxq 'disable --now gdc-poc-winddown-watch@gdc-node4-ml.service' "$tmp/systemctl.log"
! grep -Fq 'gdc-version-collector' "$tmp/systemctl.log"
jq -e '(.systemd_units|length)==1 and .systemd_units[0].unit == "gdc-poc-winddown-watch@gdc-node4-ml.service"' \
  "$ml_archive/reset-genesis-receipt.json" >/dev/null
jq -e '.projects == ["gdc-node4-ml"] and (.moved_paths | length) == 1 and .moved_paths[0].before == "/srv/dai/deploy/gdc-node4-ml" and (.preserved_paths | index("/srv/dai/hf-cache") != null) and (.preserved_paths | index("/srv/hf-cache") != null)' \
  "$ml_archive/reset-genesis-receipt.json" >/dev/null

# The ML-only mode is deliberately not a generic project-reset escape hatch.
set +e
env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
  "$ROOT/scripts/reset-genesis-host.sh" gdc-node8 20261020T120000Z --ml-project gdc-node4-ml >"$tmp/ml-invalid.out" 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]]
grep -Fq 'ML-only reset is permitted only for gdc-node9' "$tmp/ml-invalid.out"

# Exact legacy sidecars on node2/node10 and the separately composed node11
# router are captured, stopped, restart-disabled, and receipt-bound.
fixture_reset
run_legacy_reset gdc-node2 node2 >"$tmp/legacy-node2.out"
grep -Fxq 'stop legacy-router' "$tmp/docker.log"
grep -Fxq 'stop legacy-mlnode' "$tmp/docker.log"
grep -Fxq 'restart-no legacy-router' "$tmp/docker.log"
grep -Fxq 'restart-no legacy-mlnode' "$tmp/docker.log"
jq -e '(.containers|length)==2 and all(.containers[]; .legacy_sidecar == true and .final_state == "exited" and .restart_policy == "no")' \
  /srv/dai-archives/20261020T120000Z-gdc-node2/reset-genesis-receipt.json >/dev/null
jq -e '(.legacy_sidecar_ids|length)==2' \
  /srv/dai-archives/20261020T120000Z-gdc-node2/reset-genesis-intent.json >/dev/null
[[ -f /srv/dai-archives/20261020T120000Z-gdc-node2/deploy/.three-model-layout-sidecar/nginx.conf || ! -e /srv/dai/deploy ]]
[[ -f /srv/hf-cache/keep ]]

fixture_reset
run_legacy_reset gdc-node10 node10 >"$tmp/legacy-node10.out"
grep -Fxq 'stop legacy-router' "$tmp/docker.log"
jq -e '(.containers|length)==1 and .containers[0].legacy_sidecar == true' \
  /srv/dai-archives/20261020T120000Z-gdc-node10/reset-genesis-receipt.json >/dev/null
jq -e '(.legacy_sidecar_ids|length)==1' \
  /srv/dai-archives/20261020T120000Z-gdc-node10/reset-genesis-intent.json >/dev/null

fixture_reset
mkdir -p /srv/dai/deploy/model-layout-7b-4b
printf 'router config\n' >/srv/dai/deploy/model-layout-7b-4b/compose.yaml
run_legacy_reset gdc-node11 node11 >"$tmp/legacy-node11.out"
grep -Fxq 'stop legacy-dual-router' "$tmp/docker.log"
jq -e '.containers[0].legacy_sidecar == true and .containers[0].restart_policy == "no"' \
  /srv/dai-archives/20261020T120000Z-gdc-node11/reset-genesis-receipt.json >/dev/null
jq -e '.legacy_sidecar_ids==["legacy-dual-router"]' \
  /srv/dai-archives/20261020T120000Z-gdc-node11/reset-genesis-intent.json >/dev/null
[[ -f /srv/dai-archives/20261020T120000Z-gdc-node11/deploy/model-layout-7b-4b/compose.yaml ]]

# Name match alone is not authority: changed mount, network, or image makes
# the unlabelled container unknown and causes a pre-mutation refusal.
for variant in mount network image; do
  fixture_reset
  set +e
  env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
    GDC_TEST_LEGACY_LAYOUT=node2 GDC_TEST_LEGACY_UNSAFE="$([[ "$variant" == mount ]] && echo true || echo false)" \
    GDC_TEST_LEGACY_UNSAFE_NETWORK="$([[ "$variant" == network ]] && echo true || echo false)" \
    GDC_TEST_LEGACY_UNSAFE_IMAGE="$([[ "$variant" == image ]] && echo true || echo false)" \
    "$ROOT/scripts/reset-genesis-host.sh" gdc-node2 20261020T120000Z >"$tmp/legacy-unsafe-$variant.out" 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]]
  grep -Fq 'running non-reset container legacy-router' "$tmp/legacy-unsafe-$variant.out"
  [[ -f /srv/dai/deploy/compose.yaml && ! -e /srv/dai-archives/20261020T120000Z-gdc-node2 ]]
  ! grep -Fq 'stop ' "$tmp/docker.log"
done

# The active symlink target and another path explicitly bound by this Host's
# project are archived, while unbound generations remain untouched.
fixture_reset
make_generation_layout data.generations/generation-active
GDC_TEST_GENERATION_BIND=true run_reset >"$tmp/relative-generation.out"
archive=/srv/dai-archives/20261020T120000Z-gdc-node0
[[ "$(readlink "$archive/data")" == data.generations/generation-active ]]
[[ "$(readlink -e "$archive/data")" == "$archive/data.generations/generation-active" ]]
[[ -f "$archive/data.generations/generation-active/inference/state" ]]
[[ -f "$archive/data.generations/generation-bound/api/state" ]]
[[ -d /srv/dai/data.generations/generation-unbound ]]
[[ ! -e /srv/dai/data.generations/generation-active && ! -e /srv/dai/data.generations/generation-bound ]]
jq -e '(.moved_paths | length) == 8' "$archive/reset-genesis-receipt.json" >/dev/null

# An absolute link is accepted only when it points to an immediate real child;
# the original link text and generation hierarchy remain in the archive.
fixture_reset
rm -rf -- /srv/dai/data
mkdir -p /srv/dai/data.generations/generation-absolute/inference
printf 'absolute active chain\n' >/srv/dai/data.generations/generation-absolute/inference/state
ln -s /srv/dai/data.generations/generation-absolute /srv/dai/data
run_reset >"$tmp/absolute-generation.out"
archive=/srv/dai-archives/20261020T120000Z-gdc-node0
[[ "$(readlink "$archive/data")" == /srv/dai/data.generations/generation-absolute ]]
[[ -f "$archive/data.generations/generation-absolute/inference/state" ]]

# An exact DATA_DIR generation path is included in the Host reset inventory,
# while its unrelated sibling remains untouched.
fixture_reset
mkdir -p /srv/dai/data.generations/generation-env/inference \
  /srv/dai/data.generations/generation-env-unrelated
printf 'env-selected chain\n' >/srv/dai/data.generations/generation-env/inference/state
printf 'unrelated generation\n' >/srv/dai/data.generations/generation-env-unrelated/keep
printf 'DATA_DIR=/srv/dai/data.generations/generation-env\n' >/srv/dai/deploy/.env
run_reset >"$tmp/env-generation.out"
archive=/srv/dai-archives/20261020T120000Z-gdc-node0
[[ -f "$archive/data.generations/generation-env/inference/state" ]]
[[ -f /srv/dai/data.generations/generation-env-unrelated/keep ]]
[[ ! -e /srv/dai/data.generations/generation-env ]]
jq -e '.moved_paths | any(.before == "/srv/dai/data.generations/generation-env")' \
  "$archive/reset-genesis-receipt.json" >/dev/null

# A configured generation may not have been created before the reset. Its
# absence is not a reset blocker, and unrelated existing generations remain.
fixture_reset
mkdir -p /srv/dai/data.generations/generation-env-unrelated
printf 'unrelated generation\n' >/srv/dai/data.generations/generation-env-unrelated/keep
printf 'DATA_DIR=/srv/dai/data.generations/generation-not-yet-created\n' >/srv/dai/deploy/.env
run_reset >"$tmp/absent-generation.out"
archive=/srv/dai-archives/20261020T120000Z-gdc-node0
[[ -f "$archive/data/inference/state" ]]
[[ -f /srv/dai/data.generations/generation-env-unrelated/keep ]]
[[ ! -e /srv/dai/data.generations/generation-not-yet-created ]]
! jq -e '.moved_paths | any(.before == "/srv/dai/data.generations/generation-not-yet-created")' \
  "$archive/reset-genesis-receipt.json" >/dev/null

# An absent generations parent is also a valid empty scope; normal validator
# state is archived and independent roots stay in place.
fixture_reset
printf 'DATA_DIR=/srv/dai/data.generations/generation-no-parent\n' >/srv/dai/deploy/.env
run_reset >"$tmp/absent-generation-parent.out"
archive=/srv/dai-archives/20261020T120000Z-gdc-node0
[[ -f "$archive/data/inference/state" ]]
[[ ! -e /srv/dai/data.generations ]]
[[ -f /srv/dai/ops/keep && -f /srv/hf-cache/keep ]]

# DATA_DIR cannot select a symlinked generation or a nested path; refusal is
# pre-mutation and leaves all source data in place.
fixture_reset
mkdir -p /srv/dai/data.generations/generation-link-target
ln -s /srv/dai/data.generations/generation-link-target /srv/dai/data.generations/generation-link
printf 'DATA_DIR=/srv/dai/data.generations/generation-link\n' >/srv/dai/deploy/.env
set +e
run_reset >"$tmp/symlink-data-dir.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'DATA_DIR generation is not an immediate real directory' "$tmp/symlink-data-dir.out"
[[ -d /srv/dai/data.generations/generation-link-target ]]
[[ ! -e /srv/dai-archives/20261020T120000Z-gdc-node0 ]]
if grep -Fq 'stop core-container' "$tmp/docker.log"; then exit 1; fi

fixture_reset
mkdir -p /srv/dai/data.generations/generation-one /srv/dai/data.generations/generation-two
printf 'DATA_DIR=/srv/dai/data.generations/generation-one\n' >/srv/dai/deploy/.env
printf 'DATA_DIR=/srv/dai/data.generations/generation-two\n' >/srv/dai/deploy/gdc-node0/.env
set +e
run_reset >"$tmp/conflicting-data-dir.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'conflicting DATA_DIR generation paths' "$tmp/conflicting-data-dir.out"
[[ -d /srv/dai/data.generations/generation-one && -d /srv/dai/data.generations/generation-two ]]
[[ ! -e /srv/dai-archives/20261020T120000Z-gdc-node0 ]]
if grep -Fq 'stop core-container' "$tmp/docker.log"; then exit 1; fi

# Escaping links and foreign binds to generations refuse before any mutation.
fixture_reset
rm -rf -- /srv/dai/data
ln -s /srv/dai/shared /srv/dai/data
set +e
run_reset >"$tmp/escaped-generation.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'unsupported /srv/dai/data symlink target' "$tmp/escaped-generation.out"
if grep -Fq 'stop core-container' "$tmp/docker.log"; then exit 1; fi
[[ ! -e /srv/dai-archives/20261020T120000Z-gdc-node0 ]]

fixture_reset
make_generation_layout data.generations/generation-active
set +e
env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log" \
  GDC_TEST_FOREIGN_GENERATION_BIND=true \
  "$ROOT/scripts/reset-genesis-host.sh" gdc-node0 20261020T120000Z >"$tmp/foreign-generation.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'project=broker-a) binds data generation' "$tmp/foreign-generation.out"
if grep -Fq 'stop core-container' "$tmp/docker.log"; then exit 1; fi
[[ ! -e /srv/dai-archives/20261020T120000Z-gdc-node0 ]]

# Every DATA_DIR declaration is validated, not only the last matching file.
fixture_reset
printf 'DATA_DIR=/srv/dai/not-owned\nCOMPOSE_PROJECT_NAME=gdc-node0\n' >/srv/dai/deploy/.env
set +e
run_reset >"$tmp/data-dir.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'unrecognized DATA_DIR in /srv/dai/deploy/.env' "$tmp/data-dir.out"
[[ -f /srv/dai/data/inference/state ]]
if grep -Fq 'stop core-container' "$tmp/docker.log"; then exit 1; fi

# An unrelated project binding old chain data blocks before any stop or move.
fixture_reset
set +e
env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_EXTERNAL_BIND=true \
  "$ROOT/scripts/reset-genesis-host.sh" gdc-node0 20261020T120000Z >"$tmp/external.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'running non-reset container outsider' "$tmp/external.out"
[[ ! -e /srv/dai-archives/20261020T120000Z-gdc-node0 ]]
if grep -Fq 'stop core-container' "$tmp/docker.log"; then exit 1; fi

# A nested mount under moved state blocks before any mutation.
fixture_reset
set +e
env PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  GDC_TEST_DOCKER_LOG="$tmp/docker.log" GDC_TEST_EXTRA_MOUNT=true \
  "$ROOT/scripts/reset-genesis-host.sh" gdc-node0 20261020T120000Z >"$tmp/mount.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'mounted path is inside reset archive scope' "$tmp/mount.out"
[[ ! -e /srv/dai-archives/20261020T120000Z-gdc-node0 ]]

# Existing archive destinations and open host process handles are preserved.
fixture_reset
mkdir -p /srv/dai-archives/20261020T120000Z-gdc-node0
set +e
run_reset >"$tmp/collision.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'archive destination already exists' "$tmp/collision.out"
[[ -f /srv/dai/data/inference/state ]]
rm -rf -- /srv/dai-archives
exec {held_fd}< /srv/dai/data/inference/state
set +e
run_reset >"$tmp/held.out" 2>&1
rc=$?
set -e
exec {held_fd}<&-
[[ $rc -ne 0 ]]
grep -Fq 'Host process' "$tmp/held.out"
[[ -f /srv/dai/data/inference/state ]]
jq -e '.kind == "gdc-new-genesis-reset-interrupted" and .path_states[1].source_present == true and .path_states[1].archive_present == false' \
  /srv/dai-archives/20261020T120000Z-gdc-node0/reset-genesis-interrupted.json >/dev/null
[[ "$(stat -c '%a' /srv/dai-archives/20261020T120000Z-gdc-node0/reset-genesis-interrupted.json)" == 444 ]]

printf 'PASS new-Genesis reset archives only the validator roots and preserves independent paths\n'
