#!/usr/bin/env bash
# Change peer discovery on one explicitly selected Host; retain its peer configuration.
set -Eeuo pipefail
umask 077
die() { printf 'host peers: %s\n' "$*" >&2; exit 2; }
valid_alias() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
render_peers() {
  jq --arg pex "$1" '
    .services.node.environment.CONFIG_p2p__pex=$pex |
    if .services.node.command[0] == "start" then
      .services.node.command |= (reduce .[] as $arg ({args:[],skip:false};
        if .skip then .skip=false
        elif $arg == "--p2p.pex" then .skip=true
        elif ($arg | startswith("--p2p.pex=")) then .
        else .args += [$arg] end) | .args + ["--p2p.pex="+$pex])
    else . end'
}
if [[ "${1:-}" == --remote ]]; then
  pex="${2:-}"
  [[ $EUID == 0 && "$pex" =~ ^(true|false)$ ]] || die 'invalid peer discovery setting or sudo authority'
  mapfile -t node_ids < <(docker ps -q --filter label=com.docker.compose.service=node)
  (( ${#node_ids[@]} == 1 )) || die 'expected one running managed node'
  container="${node_ids[0]}"
  deploy="$(docker inspect "$container" | jq -er '.[0].Config.Labels["com.docker.compose.project.working_dir"]')"
  [[ "$deploy" == /srv/dai/deploy && -f "$deploy/compose.yaml" && -f "$deploy/.env" ]] || die 'invalid managed deployment'
  exec 8>"$deploy/.gdc-peers.lock"
  flock -n 8 || die 'another peer update is running'
  next="$(mktemp "$deploy/.peers.XXXXXX.json")"
  trap 'rm -f -- "$next"' EXIT
  docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile '*' config --format json \
    | render_peers "$pex" >"$next"
  docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$next" --profile '*' config --quiet
  data="$(docker inspect "$container" | jq -er '.[0].Mounts[] | select(.Destination=="/root/.inference" and .Type=="bind") | .Source')"
  [[ "$data" == /srv/dai/data/inference && -f "$data/config/config.toml" ]] || die 'unexpected chain config location'
  backup="$(mktemp "$deploy/compose.before-peers.XXXXXX")"
  cp -p "$deploy/compose.yaml" "$backup"
  cp -p "$data/config/config.toml" "$backup.config.toml"
  docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" stop node
  awk -v pex="$pex" '
    /^\[/ {p2p=($0=="[p2p]")}
    p2p && /^pex[[:space:]]*=/ {print "pex = " pex;next}
    {print}
  ' "$data/config/config.toml" >"$backup.config.next"
  install -m 0600 "$backup.config.next" "$data/config/config.toml"
  mv "$next" "$deploy/compose.yaml"
  docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" up -d --no-deps --pull never node
  deadline=$((SECONDS+120))
  while ((SECONDS<deadline)); do
    current="$(docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps -q node)"
    if [[ -n "$current" ]] && docker exec "$current" sh -c 'cat /root/.inference/config/config.toml' >"$next" 2>/dev/null; then
      if grep -Fqx "pex = $pex" "$next"; then
        printf 'PASS peer discovery updated; existing peers, chain data and signer retained\n'
        exit 0
      fi
    fi
    sleep 3
  done
  die "peer discovery setting did not become effective; previous Compose retained at $backup"
fi
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
pex=''; target=''
while (($#)); do
  case "$1" in
    --pex) [[ -z "$pex" && "${2:-}" =~ ^(true|false)$ ]] || die 'expected --pex true|false once'; pex="$2"; shift 2 ;;
    --*) die 'expected --pex true|false TARGET_ALIAS' ;;
    *) [[ -z "$target" ]] || die 'one target is required'; target="$1"; shift ;;
  esac
done
valid_alias "$target" && [[ "$pex" =~ ^(true|false)$ ]] || die 'expected --pex true|false TARGET_ALIAS'
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$target" "sudo -n bash -s -- --remote '$pex'" <"${BASH_SOURCE[0]}"
