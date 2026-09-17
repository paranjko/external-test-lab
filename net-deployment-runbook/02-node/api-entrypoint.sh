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

runtime_receipt="$dapi_home/gdc-join-dapi-runtime.env"

verify_join_receipt() {
  [ -r "$runtime_receipt" ] || {
    printf 'ERROR generated JOIN DAPI runtime receipt is missing\n' >&2
    exit 1
  }
  receipt_version="$(sed -n 's/^DAPI_VERSION=//p' "$runtime_receipt")"
  receipt_commit="$(sed -n 's/^DAPI_COMMIT=//p' "$runtime_receipt")"
  receipt_archive_sha256="$(sed -n 's/^DAPI_ARCHIVE_SHA256=//p' "$runtime_receipt")"
  receipt_binary_sha256="$(sed -n 's/^DAPI_BINARY_SHA256=//p' "$runtime_receipt")"
  [ "$receipt_version" = "$join_version" ] \
    && [ "$receipt_commit" = "$join_commit" ] \
    && [ "$receipt_archive_sha256" = "$join_sha256" ] \
    && printf '%s' "$receipt_binary_sha256" | grep -Eq '^[0-9a-f]{64}$' || {
      printf 'ERROR generated JOIN DAPI runtime receipt does not match profile\n' >&2
      exit 1
    }
  actual_binary_sha256="$(sha256sum "$binary" | awk '{print $1}')"
  [ "$actual_binary_sha256" = "$receipt_binary_sha256" ] || {
    printf 'ERROR generated JOIN DAPI binary does not match runtime receipt\n' >&2
    exit 1
  }
}

install_join_binary() {
  # BusyBox mktemp requires trailing Xs without a suffix
  archive="$(mktemp /tmp/gdc-join-dapi.XXXXXX)"
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
  binary_sha256="$(sha256sum "$candidate" | awk '{print $1}')"
  receipt_tmp="${runtime_receipt}.tmp"
  umask 077
  {
    printf 'DAPI_VERSION=%s\n' "$join_version"
    printf 'DAPI_COMMIT=%s\n' "$join_commit"
    printf 'DAPI_ARCHIVE_SHA256=%s\n' "$actual_sha256"
    printf 'DAPI_BINARY_SHA256=%s\n' "$binary_sha256"
  } >"$receipt_tmp"
  mv "$receipt_tmp" "$runtime_receipt"
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
    verify_join_receipt
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
