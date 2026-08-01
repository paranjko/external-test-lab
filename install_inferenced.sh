#!/bin/sh
# Install an OS-specific inferenced CLI from Gonka releases
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/paranjko/external-test-lab/refs/heads/main/install_inferenced.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/paranjko/external-test-lab/refs/heads/main/install_inferenced.sh | sh -s -- 0.2.15
#
# Optional:
#   INSTALL_DIR=/usr/local/bin sh install_inferenced.sh
#   INFERENCED_VERSION=0.2.15 sh install_inferenced.sh

set -eu

RELEASES_URL='https://api.github.com/repos/gonka-ai/gonka/releases?per_page=100'
RELEASES_PAGE=''
INSTALL_DIR=${INSTALL_DIR:-"$HOME/.local/bin"}
OS=$(uname -s)
MACHINE=$(uname -m)
WORKDIR=''
ARCHIVE=''
TEMP_BINARY=''
REQUESTED_VERSION=${1:-${INFERENCED_VERSION:-}}

[ "$#" -le 1 ] || fail 'usage: install_inferenced.sh [VERSION]'

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

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v unzip >/dev/null 2>&1 || fail 'unzip is required'
command -v awk >/dev/null 2>&1 || fail 'awk is required'

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
if [ -n "$REQUESTED_VERSION" ]; then
  case "$REQUESTED_VERSION" in
    release/v[0-9]*.[0-9]*.[0-9]*) RELEASE_TAG="$REQUESTED_VERSION" ;;
    v[0-9]*.[0-9]*.[0-9]*) RELEASE_TAG="release/$REQUESTED_VERSION" ;;
    [0-9]*.[0-9]*.[0-9]*) RELEASE_TAG="release/v$REQUESTED_VERSION" ;;
    *) fail "invalid version: $REQUESTED_VERSION (expected 0.2.15, v0.2.15, or release/v0.2.15)" ;;
  esac
else
  RELEASES_PAGE="$WORKDIR/releases.json"
  printf '%s\n' 'Resolving the newest published inferenced release...'
  curl -fsSL --retry 3 --retry-delay 1 -o "$RELEASES_PAGE" "$RELEASES_URL"

  # GitHub returns releases newest-first. Keep prereleases with a normal
  # release/vX.Y.Z tag: the current CLI release can be marked prerelease.
  RELEASE_TAG=$(awk -F '"' '
    /"tag_name"/ {
      tag = $4
      if (tag ~ /^release\/v[0-9]+\.[0-9]+\.[0-9]+$/) {
        print tag
        exit
      }
    }
  ' "$RELEASES_PAGE")
  [ -n "$RELEASE_TAG" ] || fail 'no published release/vX.Y.Z tag was found'
fi

ASSET="inferenced-$PLATFORM-$ARCH.zip"
DOWNLOAD_URL="https://github.com/gonka-ai/gonka/releases/download/$RELEASE_TAG/$ASSET"
ARCHIVE="$WORKDIR/$ASSET"

printf '%s\n' "Downloading inferenced $RELEASE_TAG for $PLATFORM-$ARCH..."
curl -fsSL --retry 3 --retry-delay 1 -o "$ARCHIVE" "$DOWNLOAD_URL" || \
  fail "the release does not provide $ASSET"

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
