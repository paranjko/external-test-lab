#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 ]] || {
  echo 'usage: verify-devshard-archive.sh PROTOCOL URL SHA256 CACHE_DIR' >&2
  exit 2
}

protocol="$1"
url="$2"
expected_sha="$3"
cache_dir="$4"
[[ "$protocol" =~ ^v[1-9][0-9]*$ ]] || { echo "invalid DevShard protocol: $protocol" >&2; exit 2; }
[[ "$url" =~ ^https?:// || "$url" =~ ^file:// ]] || { echo "invalid DevShard archive URL: $url" >&2; exit 2; }
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid DevShard archive SHA-256: $expected_sha" >&2; exit 2; }
mkdir -p "$cache_dir"
target="$cache_dir/$protocol.zip"
binding="$cache_dir/$protocol.source.json"
actual_sha=''
binding_matches=false
refresh_binding=false

if [[ -s "$target" ]]; then
  actual_sha="$(sha256sum "$target" | awk '{print $1}')"
fi
if [[ -s "$binding" ]] && jq -e --arg url "$url" --arg sha "$expected_sha" \
  '.url == $url and .sha256 == $sha' "$binding" >/dev/null 2>&1; then
  binding_matches=true
fi
if [[ "$actual_sha" != "$expected_sha" || "$binding_matches" != true ]]; then
  rm -f "$target.part"
  curl -fsSL --show-error --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 1800 \
    --output "$target.part" "$url"
  actual_sha="$(sha256sum "$target.part" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$target.part"
    echo "DevShard $protocol archive checksum mismatch: expected=$expected_sha actual=$actual_sha url=$url" >&2
    exit 1
  fi
  mv "$target.part" "$target"
  refresh_binding=true
fi
if ! unzip -tq "$target" >/dev/null; then
  echo "DevShard $protocol archive is not a readable ZIP: $target" >&2
  exit 1
fi
mapfile -t members < <(zipinfo -1 "$target")
if [[ ${#members[@]} -ne 1 || "${members[0]:-}" != devshardd ]]; then
  echo "DevShard $protocol archive must contain exactly one root devshardd executable" >&2
  exit 1
fi
verify_dir="$(mktemp -d "$cache_dir/.verify-$protocol.XXXXXX")"
cleanup() { rm -rf "$verify_dir"; }
trap cleanup EXIT
unzip -qq "$target" devshardd -d "$verify_dir"
binary="$verify_dir/devshardd"
if [[ ! -f "$binary" || ! -x "$binary" || -L "$binary" ]]; then
  echo "DevShard $protocol archive member is not a regular executable: devshardd" >&2
  exit 1
fi
elf_header="$(od -An -v -tx1 -N20 "$binary" | tr -d ' \n')"
if [[ ! "$elf_header" =~ ^7f454c460201[0-9a-f]{20}(0200|0300)3e00$ ]]; then
  echo "DevShard $protocol executable is not an ELF 64-bit little-endian x86-64 executable" >&2
  exit 1
fi
if ! LC_ALL=C grep -aFq 'GOOS=linux' "$binary" \
  || ! LC_ALL=C grep -aFq 'GOARCH=amd64' "$binary"; then
  echo "DevShard $protocol executable is not built for linux/amd64" >&2
  exit 1
fi
if ! LC_ALL=C grep -aEq "(^|[^[:alnum:]_.-])main\\.Version=${protocol}([^[:alnum:]_.-]|$)" "$binary" \
  || ! LC_ALL=C grep -aEq "(^|[^[:alnum:]_.-])devshard/types\\.buildStateRootProtocolVersion=${protocol}([^[:alnum:]_.-]|$)" "$binary"; then
  echo "DevShard $protocol executable build metadata reports another protocol" >&2
  exit 1
fi
if [[ "$refresh_binding" == true ]]; then
  binding_tmp="$(mktemp "$cache_dir/.source-$protocol.XXXXXX")"
  jq -n --arg url "$url" --arg sha256 "$expected_sha" \
    '{url:$url,sha256:$sha256}' >"$binding_tmp"
  chmod 0644 "$binding_tmp"
  mv -fT -- "$binding_tmp" "$binding"
fi
printf 'PASS DevShard artifact protocol=%s sha256=%s source=%s\n' "$protocol" "$expected_sha" "$url"
