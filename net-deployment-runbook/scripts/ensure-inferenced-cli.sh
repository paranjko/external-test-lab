#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/profile.sh"
load_profiles

note() {
  [[ "${GDC_INFERENCED_CLI_QUIET:-false}" == true ]] || printf '%s\n' "$*"
}

platform_key() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os/$arch" in
    Linux/x86_64) printf '%s\n' LINUX_AMD64 ;;
    Linux/aarch64|Linux/arm64) printf '%s\n' LINUX_ARM64 ;;
    Darwin/x86_64) printf '%s\n' DARWIN_AMD64 ;;
    Darwin/arm64) printf '%s\n' DARWIN_ARM64 ;;
    *) die "unsupported operator platform for inferenced: $os/$arch" ;;
  esac
}

version_matches() {
  local candidate="$1" output
  [[ -x "$candidate" ]] || return 1
  output="$("$candidate" version 2>&1 || true)"
  [[ "$output" =~ (^|[^0-9])v?${GONKA_RELEASE//./\\.}([^0-9]|$) ]]
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

key="$(platform_key)"
url_var="INFERENCED_OPERATOR_URL_${key}"
sha_var="INFERENCED_OPERATOR_SHA256_${key}"
url="${!url_var:-}"
expected_sha="${!sha_var:-}"
[[ -n "$url" && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "missing pinned inferenced CLI artifact for $key in $GDC_RELEASE_PROFILE"

bin_dir="${GDC_INFERENCED_BIN_DIR:-$HOME/.local/bin}"
target="$bin_dir/inferenced"
current="$(command -v inferenced 2>/dev/null || true)"
if [[ -n "$current" ]] && version_matches "$current"; then
  note "PASS operator inferenced CLI: $current ($GONKA_RELEASE)"
  exit 0
fi
if version_matches "$target"; then
  note "PASS operator inferenced CLI: $target ($GONKA_RELEASE)"
  exit 0
fi

if [[ "${GDC_INFERENCED_CLI_QUIET:-false}" == true ]]; then
  printf 'INSTALL pinned inferenced release=%s platform=%s\n' "$GONKA_RELEASE" "$key" >&2
else
  step "Install pinned inferenced $GONKA_RELEASE for $key"
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'WAIT download pinned inferenced CLI url=%s timeout_seconds=600\n' "$url" >&2
if ! curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$tmp/inferenced.zip"; then
  die "failed to download pinned inferenced CLI from $url within timeout_seconds=600"
fi
actual_sha="$(sha256_file "$tmp/inferenced.zip")"
[[ "$actual_sha" == "$expected_sha" ]] || die "inferenced CLI checksum mismatch: expected $expected_sha, got $actual_sha"
unzip -q "$tmp/inferenced.zip" -d "$tmp/unpacked"
binary="$(find "$tmp/unpacked" -type f -name inferenced -perm -u+x -print -quit)"
[[ -n "$binary" ]] || die 'pinned inferenced archive does not contain an executable inferenced binary'
install -d -m 0755 "$bin_dir"
install -m 0755 "$binary" "$target"
version_matches "$target" || die "installed inferenced does not report required version $GONKA_RELEASE"
note "PASS operator inferenced CLI installed: $target ($GONKA_RELEASE)"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  note "NOTE add $bin_dir to PATH to invoke inferenced directly"
fi
