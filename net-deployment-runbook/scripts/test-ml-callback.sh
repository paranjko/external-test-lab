#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" || fail "missing expected text: $2"; }

make_script_fixture() {
  local source="$1" dest="$2" base="$3" root
  cp "$source" "$dest"
  for root in /srv/dai/deploy /etc/gonka /usr/local/sbin; do
    sed -i "s@${root}@${base}${root}@g" "$dest"
  done
}

run_apply_case() {
  local layout="$1" should_fail="$2" base
  base="$tmp/$layout-$should_fail"
  local deploy="$base/srv/dai/deploy" conf="$base/etc/gonka" bin="$base/bin"
  local env_file original firewall apply events rules mode owner rc
  [[ "$layout" == legacy ]] && deploy="$deploy/old-project"
  mkdir -p "$deploy" "$conf" "$base/usr/local/sbin" "$bin"
  env_file="$deploy/.env"
  original=$'KEYRING_PASSWORD=fixture-only\nDAPI_API__POC_CALLBACK_URL=http://api:9100\nML_CALLBACK_BIND=127.0.0.1\n'
  printf '%s' "$original" >"$env_file"
  chmod 0600 "$env_file"
  mode="$(stat -c %a "$env_file")"
  owner="$(stat -c %u "$env_file")"
  printf '%s\n' DAPI_API__POC_CALLBACK_URL ML_CALLBACK_BIND >"$deploy/compose.yaml"
  : >"$deploy/compose.ml-local.yaml"
  printf '%s\n' unchanged >"$deploy/identity-sentinel"
  printf '%s\n' 'ROLE=network-gpu' 'SSH_PORT=22' 'MONITORING_CIDR=192.0.2.9/32' 'ML_CALLBACK_CIDR=192.0.2.8/32' >"$conf/host.env"
  printf '%s\n' 192.0.2.7/32 >"$conf/ml-callback-peers"
  events="$base/events"; rules="$base/rules"

  cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FIXTURE/events"
case "$1" in
  ps) printf 'api-id\n' ;;
  inspect)
    case "$3" in
      *working_dir*) printf '%s\n' "$DEPLOY" ;;
      *config_files*) printf '%s/compose.yaml,%s/compose.ml-local.yaml\n' "$DEPLOY" "$DEPLOY" ;;
      *Config.Env*)
        if [[ -f "$FIXTURE/active" ]]; then grep '^DAPI_API__POC_CALLBACK_URL=' "$DEPLOY/.env"
        else printf '%s\n' DAPI_API__POC_CALLBACK_URL=http://api:9100; fi ;;
      *PortBindings*)
        if [[ -f "$FIXTURE/active" ]]; then printf '0.0.0.0\n'
        else printf '127.0.0.1\n'; fi ;;
      *) exit 91 ;;
    esac ;;
  compose)
    if [[ "$*" == *'ps -q api'* ]]; then printf 'api-id\n'; exit 0; fi
    [[ "$*" == *'up -d --no-deps --pull never api'* ]] || exit 92
    if [[ "$FAIL" == true && ! -f "$FIXTURE/failed" ]]; then touch "$FIXTURE/failed"; exit 93; fi
    touch "$FIXTURE/active" ;;
  *) exit 94 ;;
esac
SH
  cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
printf 'default via 192.0.2.1 dev eth0\n'
SH
  for utility in iptables ip6tables; do
    cat >"$bin/$utility" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FIXTURE/rules"
case " $* " in *' -C '*) exit 1;; esac
SH
  done
  cat >"$bin/curl" <<'SH'
#!/usr/bin/env bash
[[ "$*" == *http://127.0.0.1:9100/versions* ]]
SH
  cat >"$bin/ssh" <<'SH'
#!/usr/bin/env bash
echo unexpected-ssh >&2
exit 99
SH
  chmod 0755 "$bin"/*
  firewall="$base/firewall.sh"; apply="$base/apply.sh"
  make_script_fixture "$ROOT/00-host-prep/gonka-firewall.sh" "$firewall" "$base"
  make_script_fixture "$ROOT/scripts/configure-ml-callback.sh" "$apply" "$base"
  set +e
  PATH="$bin:$PATH" FIXTURE="$base" DEPLOY="$deploy" FAIL="$should_fail" \
    bash "$apply" 192.0.2.1 192.0.2.2 "$firewall" >"$base/stdout" 2>"$base/stderr"
  rc=$?
  set -e
  if [[ "$should_fail" == true ]]; then
    (( rc != 0 )) || fail "$layout failure fixture unexpectedly succeeded"
    cmp -s "$env_file" <(printf '%s' "$original") || fail "$layout failure fixture did not restore .env"
    has "$base/stderr" 'restored environment'
    [[ "$(stat -c %a "$env_file")" == "$mode" && "$(stat -c %u "$env_file")" == "$owner" ]] || fail 'rollback changed .env ownership or mode'
    return
  fi
  (( rc == 0 )) || fail "$layout callback apply exited $rc: $(<"$base/stderr")"
  has "$env_file" DAPI_API__POC_CALLBACK_URL=http://192.0.2.1:9100
  has "$env_file" KEYRING_PASSWORD=fixture-only
  [[ "$(stat -c %a "$env_file")" == "$mode" && "$(stat -c %u "$env_file")" == "$owner" ]] || fail 'apply changed .env ownership or mode'
  [[ "$(<"$deploy/identity-sentinel")" == unchanged ]] || fail 'identity sentinel changed'
  PATH="$bin:$PATH" FIXTURE="$base" DEPLOY="$deploy" FAIL=false \
    bash "$apply" 192.0.2.1 192.0.2.2 "$firewall" >"$base/repeat.out" 2>"$base/repeat.err" || fail "idempotent apply failed: $(<"$base/repeat.err")"
  has "$base/repeat.out" 'already active'
  [[ "$(grep -Fc 'up -d --no-deps --pull never api' "$events")" == 1 ]] || fail 'idempotent apply recreated API'
  [[ "$(<"$conf/ml-callback-peers")" == $'192.0.2.7/32\n192.0.2.2/32' ]] || fail 'callback peer list was not additive'
  for peer in 192.0.2.8 192.0.2.7 192.0.2.2; do
    has "$rules" "-s $peer/32 -p tcp --dport 9100 -j ACCEPT"
  done
  ! grep -Fq -- '-A GONKA_INGRESS -p tcp --dport 9100 -j ACCEPT' "$rules" || fail 'firewall opened callback to all peers'
  ! grep -Fq fixture-only "$base/stdout" "$base/stderr" || fail 'callback apply printed fixture secret'
}

run_transport_case() {
  local failed="$1" base
  base="$tmp/transport-$failed"
  mkdir -p "$base/bin"
  cat >"$base/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FIXTURE/events"
case "$*" in
  '-G parent') printf 'hostname 192.0.2.1\n' ;;
  *worker*"getent ahostsv4 '192.0.2.1'"*) printf '192.0.2.1\n' ;;
  *parent*"getent ahostsv4 '192.0.2.2'"*) printf '192.0.2.2\n' ;;
  '-T parent mktemp -d /tmp/gdc-ml-callback.XXXXXXXX') printf '/tmp/gdc-ml-callback.fixture\n' ;;
  *parent*"sudo -n bash '/tmp/gdc-ml-callback.fixture/apply.sh' '192.0.2.1' '192.0.2.2'"*) ;;
  *worker*"sudo -n bash -s -- '192.0.2.1'"*)
    payload="$(cat)"
    [[ "$payload" == *'docker exec'* && "$payload" == *'curl -fsS'* && "$payload" == *':9100/versions'* ]] || exit 92
    [[ "$FAIL" != true ]] || exit 93 ;;
  *parent*'rm -f -- '*'/tmp/gdc-ml-callback.fixture/'*) ;;
  *) echo "unexpected SSH: $*" >&2; exit 99 ;;
esac
SH
  cat >"$base/bin/scp" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 3 && "$1" == -q && -f "$2" && "$3" == parent:/tmp/gdc-ml-callback.fixture/* ]]
SH
  chmod 0755 "$base/bin/ssh" "$base/bin/scp"
  set +e
  PATH="$base/bin:$PATH" FIXTURE="$base" FAIL="$failed" \
    bash "$ROOT/scripts/ensure-ml-callback.sh" parent worker 192.0.2.2 >"$base/out" 2>"$base/err"
  local rc=$?
  set -e
  if [[ "$failed" == false ]]; then
    (( rc == 0 )) || fail "callback transport failed: $(<"$base/err")"
    has "$base/out" 'READY remote ML callback verified'
  else
    (( rc != 0 )) || fail 'callback transport failure was not propagated'
    ! grep -Fq 'READY remote ML callback verified' "$base/out" || fail 'failed callback was reported READY'
  fi
}

run_apply_case flat false
run_apply_case legacy false
run_apply_case flat true
run_apply_case legacy true
run_transport_case false
run_transport_case true
printf 'PASS remote ML callback apply, rollback, flat/legacy layouts, idempotency and transport failure checks\n'
