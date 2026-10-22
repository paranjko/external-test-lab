#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ops-faucet-isolation.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Execute the production staging helper with transport mocks. The scp mock
# fails unless the preceding remote mkdir created its destination, reproducing
# the fresh-host failure without permitting any real SSH call.
mkdir -p "$tmp/bin" "$tmp/remote"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 2 && "$2" == "mkdir -p '/tmp/gdc-ops-"*"/rendered'" ]]
remote="${2#mkdir -p \'}"
remote="${remote%/rendered\'}"
mkdir -p "$STAGE_TEST_ROOT/remote${remote}/rendered"
printf 'ssh %s\n' "$*" >>"$STAGE_TEST_ROOT/transports.log"
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 5 && "$1" == -q && "$5" == fixture-host:/tmp/gdc-ops-*/rendered/ ]]
remote="${5#fixture-host:}"
remote="${remote%/rendered/}"
[[ -d "$STAGE_TEST_ROOT/remote${remote}/rendered" ]] || { echo 'scp destination directory was not prepared' >&2; exit 90; }
cp "$2" "$3" "$4" "$STAGE_TEST_ROOT/remote${remote}/rendered/"
printf 'scp %s\n' "$*" >>"$STAGE_TEST_ROOT/transports.log"
EOF
cat >"$tmp/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rsync %s\n' "$*" >>"$STAGE_TEST_ROOT/transports.log"
EOF
chmod +x "$tmp/bin/ssh" "$tmp/bin/scp" "$tmp/bin/rsync"
mkdir -p "$tmp/stage-render"
printf 'FAUCET_FIXTURE=ready\n' >"$tmp/stage-render/.env"
printf 'FAUCET_RUNTIME=fixture\n' >"$tmp/stage-render/faucet.env"
printf 'FAUCET_RESERVE=fixture\n' >"$tmp/stage-render/gateway-reserve-signer.env"
env -i PATH="$tmp/bin:/usr/bin:/bin" STAGE_TEST_ROOT="$tmp" \
  bash "$ROOT/scripts/stage-ops-render.sh" faucet fixture-host /tmp/gdc-ops-3823325 "$tmp/stage-render"
for file in .env faucet.env gateway-reserve-signer.env; do
  cmp "$tmp/stage-render/$file" "$tmp/remote/tmp/gdc-ops-3823325/rendered/$file"
done
grep -Fq "mkdir -p '/tmp/gdc-ops-3823325/rendered'" "$tmp/transports.log"
grep -Fq 'fixture-host:/tmp/gdc-ops-3823325/rendered/' "$tmp/transports.log"

# Run the actual production installer on the exact staged render tree. This
# catches parser/required-file mismatches that transport-only assertions miss.
e2e="$tmp/e2e"
e2e_ops="$e2e/srv/dai/ops"
e2e_faucet="$e2e_ops/faucet-runtime"
mkdir -p "$e2e/stage/04-ops/faucet" "$e2e/stage/04-ops/prometheus" \
  "$e2e/stage/rendered" "$e2e/input"
cp "$ROOT/04-ops/install-ops.sh" "$e2e/stage/04-ops/install-ops.sh"
cp "$ROOT/04-ops/compose.faucet.yaml" "$e2e/stage/04-ops/compose.faucet.yaml"
cp "$ROOT/04-ops/faucet/Dockerfile" "$ROOT/04-ops/faucet/faucet.py" "$e2e/stage/04-ops/faucet/"
cp "$tmp/remote/tmp/gdc-ops-3823325/rendered/.env" "$tmp/remote/tmp/gdc-ops-3823325/rendered/"*.env \
  "$e2e/stage/rendered/"
printf 'FAUCET_CHAIN_ID=fixture\n' >"$e2e/input/faucet.env"
printf 'FAUCET_CHAIN_ID=fixture\n' >"$e2e/input/gateway-reserve.env"
sed -i "s#DEST=/srv/dai/ops#DEST=$e2e_ops#" "$e2e/stage/04-ops/install-ops.sh"
sed -i 's/\[\[ $EUID -eq 0/[[ 1 -eq 1/' "$e2e/stage/04-ops/install-ops.sh"
sed -i 's/"$EUID" -eq 0/1 -eq 1/' "$e2e/stage/04-ops/install-ops.sh"
(cd "$e2e/stage/04-ops" && bash ./install-ops.sh --component faucet --render-dir "$e2e/stage/rendered" \
  --faucet-only --faucet-env "$e2e/input/faucet.env" --gateway-reserve-env "$e2e/input/gateway-reserve.env") >/dev/null
[[ -s "$e2e_faucet/compose.yaml" && -s "$e2e_faucet/faucet.env" && -s "$e2e_faucet/gateway-reserve-signer.env" ]]
grep -Fxq 'FAUCET_FIXTURE=ready' "$e2e_faucet/.env"
if env -i PATH="$tmp/bin:/usr/bin:/bin" STAGE_TEST_ROOT="$tmp" \
  bash "$ROOT/scripts/stage-ops-render.sh" faucet fixture-host /tmp/gdc-ops-3823326 "$tmp/missing-render" \
  >"$tmp/missing.out" 2>&1; then
  echo 'staging helper accepted a missing render directory' >&2; exit 1
fi
[[ "$(wc -l <"$tmp/transports.log")" == 2 ]] || { echo 'unexpected transport call escaped the fixture' >&2; exit 1; }

# Exercise the faucet renderer without declaring monitoring inputs. Its output
# must contain only the pinned Core build argument, not monitoring/status/L2
# configuration.
inventory="$tmp/inventory.env"
printf '%s\n' \
  'GDC_NODE_ALIASES=gdc-node0' \
  'GDC_NODE_PUBLIC_HOSTS=gdc-node0=127.0.0.1' \
  'GDC_NODE_P2P_PORTS=gdc-node0=5000' \
  'GDC_NODE_ML_HOSTS=' \
  'GDC_GENESIS_NODE=gdc-node0' \
  'GDC_GATEWAY_NODE=gdc-node0' \
  'GDC_PUBLIC_EDGE_NODE=gdc-node0' \
  'GDC_TELEGRAM_BOT_HOST=gdc-node0' >"$inventory"
GDC_HOME="$tmp/operator" \
  bash "$ROOT/04-ops/render-ops.sh" --inventory "$inventory" \
    --output-dir "$tmp/rendered" --faucet-only >/dev/null
grep -Fxq 'INFERENCED_IMAGE=ghcr.io/product-science/inferenced:0.2.14@sha256:9d0db1ba02d2b661c6e1add1a32467ccd1a23572639d90ded19c3c31d272851e' "$tmp/rendered/.env"
[[ "$(wc -l <"$tmp/rendered/.env")" == 1 ]]
[[ ! -e "$tmp/rendered/prometheus.yml" && ! -e "$tmp/rendered/Caddyfile" && ! -e "$tmp/rendered/config.js" ]]

run_install_fixture() {
  local mode="$1" fixture="$tmp/$1" ops="$tmp/$1/srv/dai/ops" faucet_ops="$tmp/$1/srv/dai/ops/faucet-runtime" installer="$tmp/$1/stage/install-ops.sh"
  mkdir -p "$fixture/stage/faucet" "$fixture/rendered" "$fixture/input"
  cp "$ROOT/04-ops/install-ops.sh" "$installer"
  cp "$ROOT/04-ops/compose.faucet.yaml" "$fixture/stage/compose.faucet.yaml"
  cp "$ROOT/04-ops/faucet/Dockerfile" "$fixture/stage/faucet/Dockerfile"
  cp "$ROOT/04-ops/faucet/faucet.py" "$fixture/stage/faucet/faucet.py"
  sed -i "s#DEST=/srv/dai/ops#DEST=$ops#" "$installer"
  # The fixture redirects every install destination into its temporary tree;
  # permit the non-root test runner only in this isolated script copy.
  sed -i 's/\[\[ $EUID -eq 0/[[ 1 -eq 1/' "$installer"
  sed -i 's/"$EUID" -eq 0/1 -eq 1/' "$installer"
  printf '%s\n' 'INFERENCED_IMAGE=ghcr.io/product-science/inferenced:0.2.14@sha256:9d0db1ba02d2b661c6e1add1a32467ccd1a23572639d90ded19c3c31d272851e' >"$fixture/rendered/.env"
  printf '%s\n' 'FAUCET_CHAIN_ID=fixture' >"$fixture/input/faucet.env"
  printf '%s\n' 'FAUCET_CHAIN_ID=fixture' >"$fixture/input/gateway-reserve.env"
  if [[ "$mode" == existing ]]; then
    mkdir -p "$ops/prometheus" "$ops/gateway" "$ops/bifrost"
    printf 'base-compose-preserved\n' >"$ops/compose.yaml"
    printf 'shared-env-preserved\n' >"$ops/.env"
    printf 'caddy-preserved\n' >"$ops/Caddyfile"
    printf 'prometheus-preserved\n' >"$ops/prometheus/prometheus.yml"
    printf 'gateway-preserved\n' >"$ops/gateway.env"
    printf 'broker-preserved\n' >"$ops/bifrost-broker.env"
  fi
  (
    cd "$fixture/stage"
    "$installer" --component faucet --render-dir "$fixture/rendered" --faucet-only \
      --faucet-env "$fixture/input/faucet.env" --gateway-reserve-env "$fixture/input/gateway-reserve.env"
  ) >/dev/null
  [[ -s "$faucet_ops/compose.yaml" && -s "$faucet_ops/faucet/Dockerfile" && -s "$faucet_ops/faucet/faucet.py" ]]
  [[ "$(stat -c '%a' "$faucet_ops/faucet.env")" == 600 && "$(stat -c '%a' "$faucet_ops/gateway-reserve-signer.env")" == 600 ]]
  if [[ "$mode" == existing ]]; then
    grep -Fxq 'base-compose-preserved' "$ops/compose.yaml"
    grep -Fxq 'shared-env-preserved' "$ops/.env"
    grep -Fxq 'caddy-preserved' "$ops/Caddyfile"
    grep -Fxq 'prometheus-preserved' "$ops/prometheus/prometheus.yml"
    grep -Fxq 'gateway-preserved' "$ops/gateway.env"
    grep -Fxq 'broker-preserved' "$ops/bifrost-broker.env"
  else
    [[ ! -e "$ops/compose.yaml" && ! -e "$ops/Caddyfile" && ! -e "$ops/prometheus/prometheus.yml" ]]
  fi
  local services
  services="$(cd "$ops" && docker compose --project-directory faucet-runtime -f faucet-runtime/compose.yaml --profile gateway-reserve config --services | sort)"
  [[ "$services" == $'faucet\ngateway-reserve-signer' ]]
  (cd "$ops" && docker compose --project-directory faucet-runtime -f faucet-runtime/compose.yaml \
    --profile gateway-reserve config --format json) \
    | jq -e '.name == "gdc-ops" and ((.services | keys | sort) == ["faucet", "gateway-reserve-signer"])' >/dev/null
}

run_install_fixture fresh
run_install_fixture existing

# The runbook must route a faucet invocation to the Genesis Host, render the
# minimal bundle and never restart the shared gateway Caddy service.
grep -Fq 'GATEWAY_NODE="$GENESIS_NODE"' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'render-ops.sh" --inventory "$INVENTORY" --output-dir "$OPS_RENDER" --faucet-only' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'stage-ops-render.sh" "$COMPONENT" "$GATEWAY_NODE" "$REMOTE" "$OPS_RENDER"' "$ROOT/scripts/phase-ops.sh"
grep -Fq "CADDY_START_COMMAND=true" "$ROOT/scripts/phase-ops.sh"
grep -Fq 'docker compose --project-directory faucet-runtime -f faucet-runtime/compose.yaml --profile gateway-reserve up' "$ROOT/scripts/phase-ops.sh"
grep -Fq -- '--faucet-only' "$ROOT/scripts/phase-ops.sh"
printf 'PASS faucet-only renderer/install preserve unrelated OPS and Compose services\n'
