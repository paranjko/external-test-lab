#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

base="${GDC_JOIN_BOOTSTRAP_URL:-https://api.gonka-dev.net/join-bootstrap}"
base="${base%/}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch_public_file() {
  local path="$1" output="$2" http_status curl_exit
  set +e
  http_status="$(curl -sS --connect-timeout 10 --max-time 60 -o "$output" -w '%{http_code}' "$base/$path")"
  curl_exit=$?
  set -e
  if [[ "$curl_exit" != 0 || ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    die "public JOIN bootstrap is unavailable: url=$base/$path http_status=${http_status:-0} curl_exit=$curl_exit curl_status=$(curl_exit_status "$curl_exit")"
  fi
}
for path in genesis/genesis.json genesis/genesis.sha256 genesis/genesis-seeds.txt profile/genesis.env topology.env gateway/join-client-key manifest.sha256; do
  mkdir -p "$tmp/$(dirname "$path")"
  fetch_public_file "$path" "$tmp/$path"
done
if grep -Eqi '^[[:space:]]*<(\!doctype|html)' "$tmp/manifest.sha256"; then
  die "public JOIN bootstrap manifest is HTML instead of checksums: url=$base/manifest.sha256; Genesis bootstrap is not published"
fi
"$ROOT/scripts/verify-join-bootstrap-manifest.sh" "$tmp" "$base" \
  || die 'public JOIN bootstrap checksum verification failed; preserve the diagnostic and wait for one consistent public bootstrap'
if [[ -n "${GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256:-}" ]]; then
  manifest_sha256="$(sha256sum "$tmp/manifest.sha256" | awk '{print $1}')"
  if [[ "$manifest_sha256" != "$GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256" ]]; then
    if [[ -e "$STATE/join-bootstrap-dispatched.manifest.sha256" ]]; then
      die 'public JOIN bootstrap changed after dispatch binding; preserve the current state and use the separately validated diagnosis or recovery workflow'
    fi
    die 'public JOIN bootstrap changed after its role topology was prepared; no Host mutation was made, so rerun the first-time JOIN command to load one consistent bundle'
  fi
fi
grep -qx "release_profile=$GDC_RELEASE_PROFILE" "$tmp/profile/genesis.env" || die 'public join bootstrap release differs from selected profile'
grep -qx "join_bootstrap_format=$JOIN_BOOTSTRAP_FORMAT" "$tmp/profile/genesis.env" \
  || die 'public join bootstrap format is incompatible with this release profile'
install -d -m 0700 "$GENESIS" "$STATE/phase-profiles" "$SECRETS"
install -m 0600 "$tmp/genesis/genesis.json" "$GENESIS/genesis.json"
install -m 0600 "$tmp/genesis/genesis.sha256" "$GENESIS/genesis.sha256"
install -m 0600 "$tmp/genesis/genesis-seeds.txt" "$GENESIS/genesis-seeds.txt"
install -m 0600 "$tmp/profile/genesis.env" "$STATE/phase-profiles/genesis.env"
install -m 0600 "$tmp/gateway/join-client-key" "$SECRETS/gateway.join-client-key"
printf 'PASS imported public join bootstrap from %s\n' "$base"
