#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # ROOT is resolved above.
source "$ROOT/scripts/lib.sh"
JOIN_PROFILE=''
ALLOW_EXPIRED=false
while (($#)); do
  case "$1" in
    --join-profile) shift; (($#)) || { echo 'missing --join-profile value' >&2; exit 2; }; JOIN_PROFILE="$1"; shift ;;
    --allow-expired) ALLOW_EXPIRED=true; shift ;;
    *) echo "Usage: $0 [--allow-expired] [--join-profile FILE]" >&2; exit 2 ;;
  esac
done
if [[ -n "$JOIN_PROFILE" ]]; then
  [[ -r "$JOIN_PROFILE" ]] || die 'JOIN profile is not readable'
  if [[ "$ALLOW_EXPIRED" == true ]]; then
    "$ROOT/scripts/join-profile.sh" validate --allow-expired "$JOIN_PROFILE" >/dev/null
  else
    "$ROOT/scripts/join-profile.sh" validate "$JOIN_PROFILE" >/dev/null
  fi
  [[ "$(jq -r .spec.target.platform "$JOIN_PROFILE")" == linux-amd64 ]] \
    || die 'JOIN profile does not support this operator platform'
  GONKA_RELEASE="$(jq -r .spec.components.core.expected_runtime.version "$JOIN_PROFILE")"
  url="$(jq -r .spec.components.core.installation.binary.url "$JOIN_PROFILE")"
  expected_sha="$(jq -r .spec.components.core.installation.binary.sha256 "$JOIN_PROFILE")"
  profile_id="$(jq -r .profile_id "$JOIN_PROFILE")"
else
  # shellcheck disable=SC1091 # ROOT is resolved above.
  source "$ROOT/scripts/profile.sh"
  load_profiles
fi

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

profile_runtime_matches() {
  local candidate="$1" output
  [[ -x "$candidate" ]] || return 1
  output="$("$candidate" version 2>&1 || true)"
  # The official operator CLI exposes its release version, but not its source
  # commit. The immutable archive digest in the Join Profile is the binary
  # identity; the resolver has already bound that asset's release tag to the
  # observed commit through GitHub's tag metadata. Requiring an unavailable
  # commit string would reject the genuine official CLI.
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
if [[ -n "$JOIN_PROFILE" ]]; then
  [[ "$key" == LINUX_AMD64 ]] || die "JOIN profile requires LINUX_AMD64, got $key"
else
  url_var="INFERENCED_OPERATOR_URL_${key}"
  sha_var="INFERENCED_OPERATOR_SHA256_${key}"
  url="${!url_var:-}"
  expected_sha="${!sha_var:-}"
fi
[[ -n "$url" && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die 'missing exact inferenced CLI artifact'

if [[ -n "$JOIN_PROFILE" ]]; then
  # Profile-bound JOIN tools must not be redirected through an inherited PATH
  # or a caller-controlled binary directory.
  bin_dir="$GDC_HOME/bin/$profile_id"
else
  bin_dir="${GDC_INFERENCED_BIN_DIR:-$HOME/.local/bin}"
fi
target="$bin_dir/inferenced"
current="$(command -v inferenced 2>/dev/null || true)"
if [[ -z "$JOIN_PROFILE" && -n "$current" ]] && version_matches "$current"; then
  note "PASS operator inferenced CLI: $current ($GONKA_RELEASE)"
  exit 0
fi
if [[ -n "$JOIN_PROFILE" ]] && profile_runtime_matches "$target" || [[ -z "$JOIN_PROFILE" ]] && version_matches "$target"; then
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
if [[ -n "$JOIN_PROFILE" ]]; then
  profile_runtime_matches "$target" || die "installed inferenced does not report required version $GONKA_RELEASE"
else
  version_matches "$target" || die "installed inferenced does not report required version $GONKA_RELEASE"
fi
note "PASS operator inferenced CLI installed: $target ($GONKA_RELEASE)"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  note "NOTE add $bin_dir to PATH to invoke inferenced directly"
fi
