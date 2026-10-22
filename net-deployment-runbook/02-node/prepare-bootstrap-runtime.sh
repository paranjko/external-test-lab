#!/usr/bin/env bash
# Prepare verified runtime bundles in the deployment staging directory only.
# Never execute Alpine/musl artifacts on the operator or Ubuntu Host.
set -Eeuo pipefail
[[ ( $# -eq 2 || ( $# -eq 3 && "$3" == --genesis-software-fragment ) ) \
  && -r "$1" && -d "$2" ]] || {
  echo 'Usage: prepare-bootstrap-runtime.sh PROFILE DEST [--genesis-software-fragment]' >&2
  exit 2
}
command -v unzip >/dev/null 2>&1 || { echo 'Bootstrap runtime requires unzip on the target Host; run Host preparation before deployment' >&2; exit 2; }
profile=$1 destination=$2
genesis_fragment=false
if [[ $# -eq 3 ]]; then
  genesis_fragment=true
  jq -e '
    .schema_version == 1 and .kind == "gdc-genesis-software-fragment"
    and .source.release_profile == "v2026.10.06"
    and (.source.release_lock_sha256 | test("^[0-9a-f]{64}$"))
    and (.source.model_profile | test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$"))
    and (.source.model_lock_sha256 | test("^[0-9a-f]{64}$"))
    and (.binary_sha256 | type == "object" and keys == ["decentralized_api","inferenced"]
      and (.inferenced | test("^[0-9a-f]{64}$"))
      and (.decentralized_api | test("^[0-9a-f]{64}$")))
    and (.spec.deployment.software | .components.node.version == "0.2.16-post1"
      and .components.api.version == "0.2.16-post1"
      and .components.node.commit == .components.api.commit
      and .components.node.upgrade.name == "v0.2.16"
      and .components.api.upgrade.name == "v0.2.16"
      and .components.node.upgrade.artifact.executable == "inferenced"
      and .components.api.upgrade.artifact.executable == "decentralized-api")
  ' "$profile" >/dev/null || { echo 'Genesis software fragment has an invalid pinned runtime identity' >&2; exit 1; }
  jq -e '
    .spec.deployment.software as $s |
    $s.schema_version == 1 and $s.platform == "linux/amd64"
    and ($s.deployment.commit | test("^[0-9a-f]{40}$"))
    and ($s.components.node.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$"))
    and ($s.components.api.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$"))
    and ($s.components.node.upgrade.artifact |
      .format == "zip" and .executable == "inferenced" and (.url | startswith("https://"))
      and (.sha256 | test("^[0-9a-f]{64}$")))
    and ($s.components.api.upgrade.artifact |
      .format == "zip" and .executable == "decentralized-api" and (.url | startswith("https://"))
      and (.sha256 | test("^[0-9a-f]{64}$")))
  ' "$profile" >/dev/null || { echo 'Genesis software fragment violates the pinned Core/DAPI artifact contract' >&2; exit 1; }
fi
for role in node api; do
  package="$destination/bootstrap-runtime/$role"
  install -d -m 0755 "$package/bin"
  url="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].upgrade.artifact.url' "$profile")"
  digest="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].upgrade.artifact.sha256' "$profile")"
  executable="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].upgrade.artifact.executable' "$profile")"
  [[ "$url" == https://* && "$digest" =~ ^[a-f0-9]{64}$ ]] || exit 1
  [[ "$role:$executable" == node:inferenced || "$role:$executable" == api:decentralized-api ]] || exit 1
  expected_binary_sha=''
  if [[ "$genesis_fragment" == true ]]; then
    case "$role" in
      node) expected_binary_sha="$(jq -er '.binary_sha256.inferenced' "$1")" ;;
      api) expected_binary_sha="$(jq -er '.binary_sha256.decentralized_api' "$1")" ;;
    esac
  fi
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
  actual_binary_sha="$(sha256sum "$package/bin/$executable" | awk '{print $1}')"
  if [[ "$genesis_fragment" == true && "$actual_binary_sha" != "$expected_binary_sha" ]]; then
    echo "Genesis $role executable SHA-256 does not match the pinned binary" >&2
    exit 1
  fi
  (cd "$package/bin" && sha256sum ./*) >"$package/SHA256SUMS"
  printf '%s\n' "$digest" >"$package/archive.sha256"
  if [[ "$genesis_fragment" == true ]]; then
    printf '%s\n' "$expected_binary_sha" >"$package/binary.sha256"
  fi
  rm -f -- "$archive"
done
