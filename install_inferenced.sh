#!/bin/sh
# Install the pinned official inferenced CLI from Gonka releases.
#
# Usage:
#   curl -fsSL https://gonka-dev.net/install_inferenced.sh | sh
#
# Optional:
#   INSTALL_DIR=/usr/local/bin sh install_inferenced.sh
#   gh attestation verify install_inferenced.sh -R paranjko/external-test-lab && sh install_inferenced.sh

set -eu

INSTALL_DIR=${INSTALL_DIR:-"$HOME/.local/bin"}
OS=$(uname -s)
MACHINE=$(uname -m)
WORKDIR=''
ARCHIVE=''
TEMP_BINARY=''
PINNED_VERSION='0.2.15'

[ "$#" -eq 0 ] || fail 'usage: install_inferenced.sh'

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

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
  "$candidate" version 2>&1 | awk -v expected="$expected" '
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
RELEASE_TAG='release/v0.2.15'
case "$PLATFORM-$ARCH" in
  linux-amd64) EXPECTED_SHA256='4e506d74491bf2636591d4088f3eebd0ac4c33e739f83bc1cd56785482a9a7ca' ;;
  linux-arm64) EXPECTED_SHA256='31dac13261d8d27ec674b42974b921c8e69959e8d41adc4d07242bc72026a650' ;;
  darwin-amd64) EXPECTED_SHA256='049a9b9dd428f7d47b5bb883f0f4737e2a75f604be5b8e682c2a3f5128bd4787' ;;
  darwin-arm64) EXPECTED_SHA256='119db2736fff15286874b987888d08d84d5991d928348f8efd415da959faa5e3' ;;
esac
ASSET="inferenced-$PLATFORM-$ARCH.zip"
DOWNLOAD_URL="https://github.com/gonka-ai/gonka/releases/download/$RELEASE_TAG/$ASSET"
ARCHIVE="$WORKDIR/$ASSET"
RELEASE_VERSION="$PINNED_VERSION"

if installed_version_matches "$INSTALL_DIR/inferenced" "$RELEASE_VERSION"; then
  printf '%s\n' "inferenced $RELEASE_TAG is already installed at $INSTALL_DIR/inferenced"
  exit 0
fi

printf '%s\n' "Downloading inferenced $RELEASE_TAG for $PLATFORM-$ARCH..."
curl -fsSL --retry 3 --retry-delay 1 -o "$ARCHIVE" "$DOWNLOAD_URL" || \
  fail "the release does not provide $ASSET"
actual_sha256=$(sha256_file "$ARCHIVE")
[ "$actual_sha256" = "$EXPECTED_SHA256" ] || fail 'downloaded archive SHA-256 does not match the pinned release artifact'

mkdir -p "$INSTALL_DIR"
TEMP_BINARY="$INSTALL_DIR/.inferenced.$$"
unzip -p "$ARCHIVE" inferenced > "$TEMP_BINARY" || \
  fail "the downloaded archive does not contain an inferenced binary"
[ -s "$TEMP_BINARY" ] || fail 'the downloaded inferenced binary is empty'
chmod 755 "$TEMP_BINARY"
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
