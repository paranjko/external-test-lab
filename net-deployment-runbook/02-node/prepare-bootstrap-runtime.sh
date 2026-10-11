#!/usr/bin/env bash
# Prepare verified runtime bundles in the deployment staging directory only.
# Never execute Alpine/musl artifacts on the operator or Ubuntu Host.
set -Eeuo pipefail
[[ $# -eq 2 && -r "$1" && -d "$2" ]] || exit 2
profile=$1 destination=$2
for role in node api; do
  package="$destination/bootstrap-runtime/$role"
  install -d -m 0755 "$package/bin"
  url="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].upgrade.artifact.url' "$profile")"
  digest="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].upgrade.artifact.sha256' "$profile")"
  executable="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].upgrade.artifact.executable' "$profile")"
  [[ "$url" == https://* && "$digest" =~ ^[a-f0-9]{64}$ ]] || exit 1
  [[ "$role:$executable" == node:inferenced || "$role:$executable" == api:decentralized-api ]] || exit 1
  archive="$package/runtime.zip"
  curl -fsSL --connect-timeout 15 --max-time 600 --retry 2 "$url" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum --check
  # Extract individual, known flat entries into explicit paths. Do not honor
  # archive paths, symlinks or executable permission bits supplied by a ZIP.
  entries="$(unzip -Z1 "$archive")"
  while IFS= read -r member; do
    case "$member" in
      # v0.2.16-post1 packages inferenced alongside decentralized-api in the
      # API archive. The archive digest remains profile-pinned; retain the
      # narrow flat-entry allow-list rather than accepting arbitrary files.
      "$executable"|inferenced|libgcc_s.so.1|libwasmvm_muslc.x86_64.a|wrapped_token.wasm) ;;
      *) echo "unsupported $role runtime archive entry: $member" >&2; exit 1 ;;
    esac
    [[ "$(printf '%s\n' "$entries" | grep -Fxc "$member")" == 1 ]] || { echo 'duplicate runtime ZIP entry' >&2; exit 1; }
    unzip -p "$archive" "$member" >"$package/bin/$member"
    [[ -s "$package/bin/$member" ]] || exit 1
    chmod 0644 "$package/bin/$member"
    [[ "$member" != inferenced ]] || chmod 0755 "$package/bin/$member"
  done <<<"$entries"
  [[ -s "$package/bin/$executable" ]] || exit 1
  chmod 0755 "$package/bin/$executable"
  (cd "$package/bin" && sha256sum ./*) >"$package/SHA256SUMS"
  printf '%s\n' "$digest" >"$package/archive.sha256"
  rm -f -- "$archive"
done
