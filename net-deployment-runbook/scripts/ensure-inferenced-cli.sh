#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # ROOT is resolved above.
source "$ROOT/scripts/lib.sh"
# shellcheck disable=SC1091 # ROOT is resolved above.
source "$ROOT/scripts/lib-lock.sh"
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

operator_root="${GDC_INTERNAL_DATA_ROOT:-${GDC_HOME:-}}"
if [[ -n "$JOIN_PROFILE" ]]; then
  [[ -n "$operator_root" ]] || die 'operator data root is unavailable for the shared inferenced CLI'
  bin_dir="$operator_root/bin/$GONKA_RELEASE"
  shared_version_dir=true
else
  bin_dir="${GDC_INFERENCED_BIN_DIR:-${operator_root:-$HOME/.local}/bin/$GONKA_RELEASE}"
  shared_version_dir=true
  [[ -z "${GDC_INFERENCED_BIN_DIR:-}" ]] || shared_version_dir=false
fi
target="$bin_dir/inferenced"
metadata="$bin_dir/artifact.env"
download_timeout_seconds="${GDC_INFERENCED_CLI_TIMEOUT_SECONDS:-600}"
[[ "$download_timeout_seconds" =~ ^[1-9][0-9]*$ && "$download_timeout_seconds" -le 600 ]] \
  || die 'GDC_INFERENCED_CLI_TIMEOUT_SECONDS must be a positive integer up to 600'
[[ ! -L "${operator_root:-$bin_dir}" && ! -L "$bin_dir" ]] || die 'shared inferenced CLI path must not be a symlink'
lock_root="${operator_root:-$bin_dir}/bin/.locks"
[[ ! -L "$(dirname "$lock_root")" && ! -L "$lock_root" ]] || die 'shared inferenced CLI lock path must not be a symlink'
install -d -m 0700 "$lock_root"
[[ ! -L "$lock_root/inferenced-$GONKA_RELEASE.lock.d" ]] || die 'shared inferenced CLI lock must not be a symlink'
lock_timeout="${GDC_INFERENCED_CLI_LOCK_TIMEOUT_SECONDS:-$((download_timeout_seconds * 4 + 60))}"
[[ "$lock_timeout" =~ ^[1-9][0-9]*$ && "$lock_timeout" -le 3600 ]] || die 'invalid inferenced CLI lock timeout'
gdc_lock_acquire "$lock_root/inferenced-$GONKA_RELEASE.lock" "$lock_timeout" \
  "timed out waiting for inferenced CLI install lock for $GONKA_RELEASE" || die "timed out waiting for inferenced CLI install lock for $GONKA_RELEASE"
lock_dir="$GDC_LOCK_DIR"
trap 'gdc_lock_release "${lock_dir:-}"' EXIT

cached_binary_valid() {
  local recorded_archive recorded_platform recorded_binary actual_binary
  [[ -f "$target" && -x "$target" && ! -L "$target" && -f "$metadata" && ! -L "$metadata" ]] || return 1
  recorded_archive="$(awk -F= '$1 == "archive_sha256" {print $2}' "$metadata")"
  recorded_platform="$(awk -F= '$1 == "platform" {print $2}' "$metadata")"
  recorded_binary="$(awk -F= '$1 == "binary_sha256" {print $2}' "$metadata")"
  [[ "$recorded_archive" == "$expected_sha" && "$recorded_platform" == "$key" && "$recorded_binary" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_binary="$(sha256_file "$target")"
  [[ "$actual_binary" == "$recorded_binary" ]] || return 1
  profile_runtime_matches "$target"
}

find_verified_join_archive() {
  local candidate legacy_node_home
  [[ -n "$JOIN_PROFILE" ]] || return 1
  for candidate in \
    "$operator_root/artifacts/inferenced/$expected_sha/inferenced.zip" \
    "$GDC_HOME/artifacts/inferenced/$expected_sha/inferenced.zip"; do
    if [[ -f "$candidate" && ! -L "$candidate" ]] \
      && [[ "$(sha256_file "$candidate")" == "$expected_sha" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  for legacy_node_home in "$operator_root"/*; do
    [[ -d "$legacy_node_home" && ! -L "$legacy_node_home" ]] || continue
    candidate="$legacy_node_home/artifacts/inferenced/$expected_sha/inferenced.zip"
    if [[ -f "$candidate" && ! -L "$candidate" ]] \
      && [[ "$(sha256_file "$candidate")" == "$expected_sha" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

adopt_verified_legacy_binary() {
  local archive adoption_tmp archive_binary binary_sha metadata_tmp entry_count
  [[ "$shared_version_dir" == true && -d "$bin_dir" && ! -L "$bin_dir" ]] || return 1
  [[ -f "$target" && -x "$target" && ! -L "$target" && ! -e "$metadata" && ! -L "$metadata" ]] || return 1
  entry_count="$(find "$bin_dir" -mindepth 1 -maxdepth 1 -printf . | wc -c)"
  [[ "$entry_count" == 1 ]] || return 1
  archive="$(find_verified_join_archive)" || return 1
  adoption_tmp="$(mktemp -d)"
  if ! unzip -q "$archive" -d "$adoption_tmp"; then
    rm -rf "$adoption_tmp"
    return 1
  fi
  archive_binary="$(find "$adoption_tmp" -type f -name inferenced -perm -u+x -print -quit)"
  if [[ -z "$archive_binary" ]] || ! profile_runtime_matches "$archive_binary" \
    || ! cmp -s "$target" "$archive_binary"; then
    rm -rf "$adoption_tmp"
    return 1
  fi
  binary_sha="$(sha256_file "$target")"
  metadata_tmp="$(mktemp "$bin_dir/.artifact.XXXXXX")"
  printf 'archive_sha256=%s\nplatform=%s\nbinary_sha256=%s\n' \
    "$expected_sha" "$key" "$binary_sha" >"$metadata_tmp"
  chmod 0644 "$metadata_tmp"
  mv "$metadata_tmp" "$metadata"
  rm -rf "$adoption_tmp"
  note "PASS adopted verified legacy inferenced CLI: $target ($GONKA_RELEASE)"
}

if cached_binary_valid; then
  note "PASS operator inferenced CLI: $target ($GONKA_RELEASE)"
  exit 0
fi
if adopt_verified_legacy_binary && cached_binary_valid; then
  exit 0
fi
if [[ -e "$target" || -L "$target" || -e "$metadata" || -L "$metadata" ]] \
  || [[ "$shared_version_dir" == true && ( -e "$bin_dir" || -L "$bin_dir" ) ]]; then
  die "conflicting or tampered shared inferenced CLI for release $GONKA_RELEASE; refusing overwrite"
fi

if [[ "${GDC_INFERENCED_CLI_QUIET:-false}" == true ]]; then
  printf 'INSTALL pinned inferenced release=%s platform=%s\n' "$GONKA_RELEASE" "$key" >&2
else
  step "Install pinned inferenced $GONKA_RELEASE for $key"
fi
tmp="$(mktemp -d)"
publish_dir=''
trap 'rm -rf "$tmp"; if [[ -n "$publish_dir" && -d "$publish_dir" ]]; then rm -rf "$publish_dir"; fi; gdc_lock_release "${lock_dir:-}"' EXIT
archive="$tmp/inferenced.zip"
if [[ -n "$JOIN_PROFILE" ]]; then
  cache_dir="$operator_root/artifacts/inferenced/$expected_sha"
  cache_archive="$cache_dir/inferenced.zip"
  [[ ! -L "$operator_root/artifacts" && ! -L "$operator_root/artifacts/inferenced" && ! -L "$cache_dir" ]] \
    || die 'shared inferenced archive cache path must not be a symlink'
  if [[ -f "$cache_archive" && ! -L "$cache_archive" ]] \
    && [[ "$(sha256_file "$cache_archive")" == "$expected_sha" ]]; then
    archive="$cache_archive"
    note "PASS cached pinned inferenced CLI sha256=$expected_sha"
  else
    [[ ! -L "$cache_archive" ]] || die 'shared inferenced archive cache must not be a symlink'
    legacy_archive="$GDC_HOME/artifacts/inferenced/$expected_sha/inferenced.zip"
    install -d -m 0700 "$cache_dir"
    if [[ -f "$legacy_archive" && ! -L "$legacy_archive" && "$(sha256_file "$legacy_archive")" == "$expected_sha" ]]; then
      install -m 0600 "$legacy_archive" "$cache_archive"
      archive="$cache_archive"
    else
      legacy_archive="$(find_verified_join_archive 2>/dev/null || true)"
      if [[ -n "$legacy_archive" ]]; then
        install -m 0600 "$legacy_archive" "$cache_archive"
        archive="$cache_archive"
      else
        printf 'WAIT download pinned inferenced CLI url=%s timeout_seconds=%s\n' "$url" "$download_timeout_seconds" >&2
        if ! curl -fL --retry 3 --connect-timeout 15 --max-time "$download_timeout_seconds" "$url" -o "$archive"; then
          die "failed to download pinned inferenced CLI from $url within timeout_seconds=$download_timeout_seconds"
        fi
        actual_sha="$(sha256_file "$archive")"
        [[ "$actual_sha" == "$expected_sha" ]] || die "inferenced CLI checksum mismatch: expected $expected_sha, got $actual_sha"
        install -m 0600 "$archive" "$cache_archive"
        archive="$cache_archive"
      fi
    fi
  fi
else
  printf 'WAIT download pinned inferenced CLI url=%s timeout_seconds=%s\n' "$url" "$download_timeout_seconds" >&2
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time "$download_timeout_seconds" "$url" -o "$archive"; then
    die "failed to download pinned inferenced CLI from $url within timeout_seconds=$download_timeout_seconds"
  fi
  actual_sha="$(sha256_file "$archive")"
  [[ "$actual_sha" == "$expected_sha" ]] || die "inferenced CLI checksum mismatch: expected $expected_sha, got $actual_sha"
fi
unzip -q "$archive" -d "$tmp/unpacked"
binary="$(find "$tmp/unpacked" -type f -name inferenced -perm -u+x -print -quit)"
[[ -n "$binary" ]] || die 'pinned inferenced archive does not contain an executable inferenced binary'
profile_runtime_matches "$binary" || die "pinned inferenced archive does not report required version $GONKA_RELEASE"
binary_sha="$(sha256_file "$binary")"
if [[ "$shared_version_dir" == true ]]; then
  install -d -m 0755 "$(dirname "$bin_dir")"
  publish_dir="$(mktemp -d "$(dirname "$bin_dir")/.inferenced-$GONKA_RELEASE.XXXXXX")"
  install -m 0755 "$binary" "$publish_dir/inferenced"
  printf 'archive_sha256=%s\nplatform=%s\nbinary_sha256=%s\n' "$expected_sha" "$key" "$binary_sha" >"$publish_dir/artifact.env"
  chmod 0644 "$publish_dir/artifact.env"
  mv "$publish_dir" "$bin_dir"
else
  [[ ! -L "$bin_dir" ]] || die 'explicit inferenced binary directory must not be a symlink'
  install -d -m 0755 "$bin_dir"
  target_tmp="$(mktemp "$bin_dir/.inferenced.XXXXXX")"
  metadata_tmp="$(mktemp "$bin_dir/.artifact.XXXXXX")"
  install -m 0755 "$binary" "$target_tmp"
  printf 'archive_sha256=%s\nplatform=%s\nbinary_sha256=%s\n' "$expected_sha" "$key" "$binary_sha" >"$metadata_tmp"
  chmod 0644 "$metadata_tmp"
  mv "$target_tmp" "$target"
  mv "$metadata_tmp" "$metadata"
fi
if [[ -n "$JOIN_PROFILE" ]]; then
  profile_runtime_matches "$target" || die "installed inferenced does not report required version $GONKA_RELEASE"
else
  version_matches "$target" || die "installed inferenced does not report required version $GONKA_RELEASE"
fi
note "PASS operator inferenced CLI installed: $target ($GONKA_RELEASE)"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  note "NOTE add $bin_dir to PATH to invoke inferenced directly"
fi
