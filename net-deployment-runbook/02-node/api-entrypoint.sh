#!/usr/bin/env sh
set -eu

dapi_home="${1:-/root/.dapi}"
case "$dapi_home" in
  /*) ;;
  *)
    printf 'ERROR DAPI home must be an absolute path\n' >&2
    exit 2
    ;;
esac

current="$dapi_home/cosmovisor/current"
binary="$current/bin/decentralized-api"
cosmovisor_home="$dapi_home/cosmovisor"

join_url="${GDC_JOIN_DAPI_UPGRADE_URL:-}"
join_sha256="${GDC_JOIN_DAPI_UPGRADE_SHA256:-}"
join_version="${GDC_JOIN_DAPI_EXPECTED_VERSION:-}"
join_commit="${GDC_JOIN_DAPI_EXPECTED_COMMIT:-}"

verify_join_binary() {
  candidate="$1"
  version_output="$($candidate version --long 2>&1)" || {
    printf 'ERROR generated JOIN DAPI binary cannot report its version\n' >&2
    exit 1
  }
  printf '%s\n' "$version_output" | grep -Eq "^version:[[:space:]]*\"?$join_version\"?$" || {
    printf 'ERROR generated JOIN DAPI binary version does not match profile\n' >&2
    exit 1
  }
  printf '%s\n' "$version_output" | grep -Eq "^commit:[[:space:]]*\"?$join_commit\"?$" || {
    printf 'ERROR generated JOIN DAPI binary commit does not match profile\n' >&2
    exit 1
  }
}

install_join_binary() {
  archive="$(mktemp /tmp/gdc-join-dapi.XXXXXX.zip)"
  candidate="$(mktemp /tmp/gdc-join-decentralized-api.XXXXXX)"
  trap 'rm -f "$archive" "$candidate"' EXIT HUP INT TERM
  curl -fsSL --connect-timeout 15 --max-time 600 "$join_url" -o "$archive" || {
    printf 'ERROR generated JOIN DAPI download failed\n' >&2
    exit 1
  }
  actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  [ "$actual_sha256" = "$join_sha256" ] || {
    printf 'ERROR generated JOIN DAPI digest does not match profile\n' >&2
    exit 1
  }
  busybox unzip -p "$archive" decentralized-api >"$candidate" || {
    printf 'ERROR generated JOIN DAPI archive is invalid\n' >&2
    exit 1
  }
  [ -s "$candidate" ] || { printf 'ERROR generated JOIN DAPI archive is empty\n' >&2; exit 1; }
  chmod 0755 "$candidate"
  verify_join_binary "$candidate"
  install -m 0755 "$candidate" /usr/bin/decentralized-api
}

if [ -n "$join_url$join_sha256$join_version$join_commit" ]; then
  case "$join_url" in https://github.com/*) ;; *) printf 'ERROR generated JOIN DAPI URL is invalid\n' >&2; exit 1 ;; esac
  printf '%s' "$join_sha256" | grep -Eq '^[0-9a-f]{64}$' || {
    printf 'ERROR generated JOIN DAPI digest is invalid\n' >&2; exit 1;
  }
  printf '%s' "$join_commit" | grep -Eq '^[0-9a-f]{40}$' || {
    printf 'ERROR generated JOIN DAPI commit is invalid\n' >&2; exit 1;
  }
  [ -n "$join_version" ] || { printf 'ERROR generated JOIN DAPI version is missing\n' >&2; exit 1; }
fi

# The upstream image entrypoint always runs `cosmovisor init`. After the first
# protocol upgrade `current` already exists, so restarting the container would
# fail before Cosmovisor can run the selected binary. Initialization is only a
# first-start operation; later starts must preserve and run the existing link.
if [ -L "$cosmovisor_home" ] \
  || { [ -e "$cosmovisor_home" ] && [ ! -d "$cosmovisor_home" ]; }; then
  printf 'ERROR initialized DAPI home has no runnable Cosmovisor current binary\n' >&2
  exit 1
fi

if [ -L "$current" ] && [ -f "$binary" ] && [ -x "$binary" ]; then
  if [ -n "$join_url" ]; then
    verify_join_binary "$binary"
  fi
  exec cosmovisor run
fi

if [ -e "$current" ] || [ -L "$current" ]; then
  printf 'ERROR initialized DAPI home has no runnable Cosmovisor current binary\n' >&2
  exit 1
fi

if [ -d "$cosmovisor_home" ] \
  && [ -n "$(find "$cosmovisor_home" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  printf 'ERROR initialized DAPI home has no runnable Cosmovisor current binary\n' >&2
  exit 1
fi

if [ -n "$join_url" ]; then
  install_join_binary
fi

exec sh ./init-docker.sh
