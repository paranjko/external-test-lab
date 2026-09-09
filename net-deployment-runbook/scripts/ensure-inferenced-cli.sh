#!/bin/sh
# Install the exact local inferenced CLI. This is local operator code: keep it
# POSIX sh and do not load the Bash-only runbook profile layer.
set -eu

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--allow-expired] [--join-profile FILE]\n' "$0" >&2
}

JOIN_PROFILE=''
ALLOW_EXPIRED=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --join-profile)
      shift
      [ "$#" -gt 0 ] || { printf 'missing --join-profile value\n' >&2; exit 2; }
      JOIN_PROFILE=$1
      ;;
    --allow-expired) ALLOW_EXPIRED=true ;;
    *) usage; exit 2 ;;
  esac
  shift
done

note() {
  [ "${GDC_INFERENCED_CLI_QUIET:-false}" = true ] || printf '%s\n' "$*"
}

platform_key() {
  gdc_platform_os=$(uname -s)
  gdc_platform_arch=$(uname -m)
  case "$gdc_platform_os/$gdc_platform_arch" in
    Linux/x86_64) printf '%s\n' LINUX_AMD64 ;;
    Linux/aarch64|Linux/arm64) printf '%s\n' LINUX_ARM64 ;;
    Darwin/x86_64) printf '%s\n' DARWIN_AMD64 ;;
    Darwin/arm64) printf '%s\n' DARWIN_ARM64 ;;
    *)
      printf 'unsupported_platform: inferenced has no supported local artifact for %s/%s\n' \
        "$gdc_platform_os" "$gdc_platform_arch" >&2
      printf 'mutation=none\n' >&2
      exit 69
      ;;
  esac
}

version_matches() {
  [ -x "$1" ] || return 1
  "$1" version 2>&1 | tr -c '0123456789.' '\n' | grep -Fx "$GONKA_RELEASE" >/dev/null 2>&1
}

lock_value() {
  gdc_lock_value_file=$1
  gdc_lock_value_key=$2
  awk -F= -v wanted="$gdc_lock_value_key" '
    $1 == wanted {
      if (++count != 1 || $2 == "") exit 2
      value = substr($0, length(wanted) + 2)
    }
    END { if (count != 1) exit 1; print value }
  ' "$gdc_lock_value_file"
}

load_release_artifact() {
  GDC_RELEASE_PROFILE=${GDC_RELEASE_PROFILE:-v2026.07.23}
  printf '%s\n' "$GDC_RELEASE_PROFILE" | grep -Eq '^[a-z0-9][a-z0-9.-]*$' \
    || die "invalid release profile: $GDC_RELEASE_PROFILE"
  gdc_release_lock=$ROOT/profiles/releases/$GDC_RELEASE_PROFILE.lock
  [ -r "$gdc_release_lock" ] || die "unknown release profile: $GDC_RELEASE_PROFILE"
  GONKA_RELEASE=$(lock_value "$gdc_release_lock" GONKA_RELEASE) \
    || die 'release profile has no valid GONKA_RELEASE'
  url=$(lock_value "$gdc_release_lock" "INFERENCED_OPERATOR_URL_$key") \
    || die "release profile has no inferenced URL for $key"
  expected_sha=$(lock_value "$gdc_release_lock" "INFERENCED_OPERATOR_SHA256_$key") \
    || die "release profile has no inferenced SHA-256 for $key"
}

load_profile_operator_artifact() {
  profile_release=$1
  profile_lock=''
  for candidate_lock in "$ROOT"/profiles/releases/*.lock; do
    [ -r "$candidate_lock" ] || continue
    candidate_release=$(lock_value "$candidate_lock" GONKA_RELEASE 2>/dev/null || true)
    if [ "$candidate_release" = "$profile_release" ]; then
      profile_lock=$candidate_lock
      break
    fi
  done
  [ -n "$profile_lock" ] || die "no release profile contains native inferenced operator for $profile_release"
  url=$(lock_value "$profile_lock" "INFERENCED_OPERATOR_URL_$key") \
    || die "release profile has no inferenced URL for $key"
  expected_sha=$(lock_value "$profile_lock" "INFERENCED_OPERATOR_SHA256_$key") \
    || die "release profile has no inferenced SHA-256 for $key"
}

gdc_require_jq || exit $?
key=$(platform_key)
if [ -n "$JOIN_PROFILE" ]; then
  [ -r "$JOIN_PROFILE" ] || die 'JOIN profile is not readable'
  if [ "$ALLOW_EXPIRED" = true ]; then
    "$ROOT/scripts/join-profile.sh" validate --allow-expired "$JOIN_PROFILE" >/dev/null
  else
    "$ROOT/scripts/join-profile.sh" validate "$JOIN_PROFILE" >/dev/null
  fi
  GONKA_RELEASE=$(jq -r .spec.components.core.expected_runtime.version "$JOIN_PROFILE")
  profile_id=$(jq -r .profile_id "$JOIN_PROFILE")
  # The JOIN target is Linux, but this CLI runs on the operator workstation.
  # Resolve the native artifact from the release lock instead of reusing the
  # target's Linux core binary URL (Darwin operators are supported).
  load_profile_operator_artifact "$GONKA_RELEASE"
else
  load_release_artifact
fi

[ -n "$url" ] && printf '%s\n' "$expected_sha" | grep -Eq '^[0-9a-f]{64}$' \
  || die 'missing exact inferenced CLI artifact'

if [ -n "$JOIN_PROFILE" ]; then
  # Profile-bound JOIN tools must not be redirected through inherited PATH.
  bin_dir=$GDC_HOME/bin/$profile_id
else
  bin_dir=${GDC_INFERENCED_BIN_DIR:-${HOME:?}/.local/bin}
fi
target=$bin_dir/inferenced
current=$(command -v inferenced 2>/dev/null || true)
if [ -z "$JOIN_PROFILE" ] && [ -n "$current" ] && version_matches "$current"; then
  note "PASS operator inferenced CLI: $current ($GONKA_RELEASE)"
  exit 0
fi
if [ -n "$JOIN_PROFILE" ] && version_matches "$target" || [ -z "$JOIN_PROFILE" ] && version_matches "$target"; then
  note "PASS operator inferenced CLI: $target ($GONKA_RELEASE)"
  exit 0
fi

if [ "${GDC_INFERENCED_CLI_QUIET:-false}" = true ]; then
  printf 'INSTALL pinned inferenced release=%s platform=%s\n' "$GONKA_RELEASE" "$key" >&2
else
  printf '\n== Install pinned inferenced %s for %s ==\n' "$GONKA_RELEASE" "$key"
fi
tmp=$(gdc_mktemp_dir)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf 'WAIT download pinned inferenced CLI url=%s timeout_seconds=600\n' "$url" >&2
if ! curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$tmp/inferenced.zip"; then
  die "failed to download pinned inferenced CLI from $url within timeout_seconds=600"
fi
actual_sha=$(gdc_sha256 "$tmp/inferenced.zip")
[ "$actual_sha" = "$expected_sha" ] \
  || die "inferenced CLI checksum mismatch: expected $expected_sha, got $actual_sha"
unzip -q "$tmp/inferenced.zip" -d "$tmp/unpacked"
binary=$tmp/unpacked/inferenced
[ -f "$binary" ] && [ -x "$binary" ] \
  || die 'pinned inferenced archive does not contain an executable inferenced binary'
mkdir -p "$bin_dir"
chmod 0755 "$bin_dir"
install -m 0755 "$binary" "$target"
version_matches "$target" \
  || die "installed inferenced does not report required version $GONKA_RELEASE"
note "PASS operator inferenced CLI installed: $target ($GONKA_RELEASE)"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) note "NOTE add $bin_dir to PATH to invoke inferenced directly" ;;
esac
