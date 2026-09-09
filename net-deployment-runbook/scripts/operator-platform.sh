#!/usr/bin/env bash
# Platform of the local operator CLI, independent of the remote Host.
operator_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os/$arch" in
    Linux/x86_64) echo linux-amd64 ;;
    Linux/aarch64|Linux/arm64) echo linux-arm64 ;;
    Darwin/x86_64) echo darwin-amd64 ;;
    Darwin/arm64) echo darwin-arm64 ;;
    *) printf 'unsupported operator platform: %s/%s\n' "$os" "$arch" >&2; return 2 ;;
  esac
}
