#!/bin/sh
# Install an official inferenced CLI from a selected Gonka release.
#
# Usage:
#   curl -fsSL https://gonka-dev.net/install_inferenced.sh | sh
#   curl -fsSL https://gonka-dev.net/install_inferenced.sh | sh -s -- 0.2.15
#
# Optional:
#   INSTALL_DIR=/usr/local/bin sh install_inferenced.sh
#   INFERENCED_VERSION=0.2.16 sh install_inferenced.sh
#   gh attestation verify install_inferenced.sh -R paranjko/external-test-lab && sh install_inferenced.sh

set -eu

INSTALL_DIR=${INSTALL_DIR:-"$HOME/.local/bin"}
OS=$(uname -s)
MACHINE=$(uname -m)
WORKDIR=''
ARCHIVE=''
TEMP_BINARY=''
REQUESTED_VERSION=${1-${INFERENCED_VERSION:-}}
RELEASES_URL='https://api.github.com/repos/gonka-ai/gonka/releases?per_page=100'

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

[ "$#" -le 1 ] || fail 'usage: install_inferenced.sh [VERSION]'
if [ "$#" -eq 1 ] || [ -n "$REQUESTED_VERSION" ]; then
  case "$REQUESTED_VERSION" in
    release/v*) RELEASE_VERSION=${REQUESTED_VERSION#release/v} ;;
    v*) RELEASE_VERSION=${REQUESTED_VERSION#v} ;;
    [0-9]*) RELEASE_VERSION=$REQUESTED_VERSION ;;
    *) fail "invalid version: $REQUESTED_VERSION" ;;
  esac
  printf '%s\n' "$RELEASE_VERSION" | awk '
    /^[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 }
    END { exit !(valid && NR == 1) }
  ' || fail "invalid version: $REQUESTED_VERSION (expected X.Y.Z, vX.Y.Z, or release/vX.Y.Z)"
else
  RELEASE_VERSION=''
fi

cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
  if [ -n "$TEMP_BINARY" ] && [ -f "$TEMP_BINARY" ]; then
    rm -f "$TEMP_BINARY"
  fi
}

trap cleanup EXIT HUP INT TERM

installed_version_matches() {
  candidate=$1
  expected=$2
  [ -x "$candidate" ] || return 1
  version_output=$("$candidate" version 2>&1) || return 1
  printf '%s\n' "$version_output" | awk -v expected="$expected" '
    {
      for (i = 1; i <= NF; i++) {
        value = $i
        sub(/^v/, "", value)
        if (value == expected) found = 1
      }
    }
    END { exit !found }
  '
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v unzip >/dev/null 2>&1 || fail 'unzip is required'
command -v awk >/dev/null 2>&1 || fail 'awk is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required to verify selected release metadata'
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail 'sha256sum or shasum is required'
  fi
}

case "$OS" in
  Linux)
    PLATFORM='linux'
    ;;
  Darwin)
    PLATFORM='darwin'
    ;;
  *)
    fail "unsupported operating system: $OS; supported systems are Linux and macOS"
    ;;
esac

case "$MACHINE" in
  x86_64|amd64)
    ARCH='amd64'
    ;;
  aarch64|arm64)
    ARCH='arm64'
    ;;
  *)
    fail "unsupported architecture: $MACHINE; supported architectures are amd64 and arm64"
    ;;
esac

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/inferenced-install.XXXXXX")
if [ -z "$RELEASE_VERSION" ]; then
  printf '%s\n' 'Resolving the newest published inferenced release...'
  curl -fsSL --retry 3 --retry-delay 1 -o "$WORKDIR/releases.json" "$RELEASES_URL" || fail 'cannot resolve published releases'
  RELEASE_VERSION=$(jq -er '[.[] | .tag_name | select(test("^release/v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0] | select(type == "string") | ltrimstr("release/v")' "$WORKDIR/releases.json") || fail 'no published release/vX.Y.Z tag was found'
fi
RELEASE_TAG="release/v$RELEASE_VERSION"
ASSET="inferenced-$PLATFORM-$ARCH.zip"
DOWNLOAD_URL="https://github.com/gonka-ai/gonka/releases/download/$RELEASE_TAG/$ASSET"
ARCHIVE="$WORKDIR/$ASSET"

if installed_version_matches "$INSTALL_DIR/inferenced" "$RELEASE_VERSION"; then
  printf '%s\n' "inferenced $RELEASE_TAG is already installed at $INSTALL_DIR/inferenced"
  exit 0
fi

curl -fsSL --retry 3 --retry-delay 1 -o "$WORKDIR/release.json" \
  "https://api.github.com/repos/gonka-ai/gonka/releases/tags/release%2Fv$RELEASE_VERSION" || fail "cannot read release metadata for $RELEASE_TAG"
EXPECTED_SHA256=$(jq -er --arg tag "$RELEASE_TAG" --arg asset "$ASSET" --arg url "$DOWNLOAD_URL" '
  select(.tag_name == $tag)
  | [.assets[] | select(.name == $asset and .browser_download_url == $url)]
  | select(length == 1) | .[0].digest
  | select(type == "string" and test("^sha256:[0-9a-f]{64}$")) | ltrimstr("sha256:")
' "$WORKDIR/release.json") || fail "release metadata lacks a unique verified SHA-256 for $ASSET in $RELEASE_TAG"

# Keep the independently pinned DevNet release hashes, without constraining
# the generic installer to that version or applying its hashes to another tag.
if [ "$RELEASE_VERSION" = '0.2.15' ]; then
  case "$PLATFORM-$ARCH" in
    linux-amd64) PINNED_SHA256='4e506d74491bf2636591d4088f3eebd0ac4c33e739f83bc1cd56785482a9a7ca' ;;
    linux-arm64) PINNED_SHA256='31dac13261d8d27ec674b42974b921c8e69959e8d41adc4d07242bc72026a650' ;;
    darwin-amd64) PINNED_SHA256='049a9b9dd428f7d47b5bb883f0f4737e2a75f604be5b8e682c2a3f5128bd4787' ;;
    darwin-arm64) PINNED_SHA256='119db2736fff15286874b987888d08d84d5991d928348f8efd415da959faa5e3' ;;
  esac
  [ "$EXPECTED_SHA256" = "$PINNED_SHA256" ] || fail 'release metadata does not match the pinned DevNet artifact'
fi

printf '%s\n' "Downloading inferenced $RELEASE_TAG for $PLATFORM-$ARCH..."
curl -fsSL --retry 3 --retry-delay 1 -o "$ARCHIVE" "$DOWNLOAD_URL" || \
  fail "the release does not provide $ASSET"
actual_sha256=$(sha256_file "$ARCHIVE")
[ "$actual_sha256" = "$EXPECTED_SHA256" ] || fail 'downloaded archive SHA-256 does not match the selected release artifact'

mkdir -p "$INSTALL_DIR"
TEMP_BINARY="$INSTALL_DIR/.inferenced.$$"
unzip -p "$ARCHIVE" inferenced > "$TEMP_BINARY" || \
  fail "the downloaded archive does not contain an inferenced binary"
[ -s "$TEMP_BINARY" ] || fail 'the downloaded inferenced binary is empty'
chmod 755 "$TEMP_BINARY"
installed_version_matches "$TEMP_BINARY" "$RELEASE_VERSION" || fail 'downloaded binary version does not match the selected release'
mv -f "$TEMP_BINARY" "$INSTALL_DIR/inferenced"
TEMP_BINARY=''

"$INSTALL_DIR/inferenced" version
printf '%s\n' "Installed $INSTALL_DIR/inferenced"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    printf '%s\n' "Add this directory to PATH to run inferenced by name: $INSTALL_DIR"
    ;;
esac
