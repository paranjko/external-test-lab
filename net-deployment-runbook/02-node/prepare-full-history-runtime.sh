#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DATA_DIR LINEAGE_RECEIPT" >&2; exit 2; }
data_dir="$1"; receipt="$2"
[[ "$data_dir" == /srv/dai/data/*.generations/* && -r "$receipt" ]] || { echo 'invalid full-history runtime input' >&2; exit 2; }
jq -e '.bootstrap.mode == "historical_replay" and .bootstrap.history.kind == "gdc-full-history-runtime-schedule"' "$receipt" >/dev/null || { echo 'full-history receipt lacks a checked runtime schedule' >&2; exit 1; }
download_runtime() {
  local url="$1" sha="$2" target="$3" tmp
  [[ "$url" =~ ^https:// && "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo 'unsafe full-history runtime record' >&2; exit 1; }
  tmp="$(mktemp "${target}.XXXXXX")"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 "$url" -o "$tmp"
  [[ "$(sha256sum "$tmp" | awk '{print $1}')" == "$sha" ]] || { rm -f "$tmp"; echo "full-history runtime checksum mismatch: $url" >&2; exit 1; }
  chmod 0755 "$tmp"; mv -f "$tmp" "$target"
}
home="$data_dir/inference/cosmovisor"
install -d -m 0755 "$home/genesis/bin" "$home/upgrades"
download_runtime "$(jq -er '.bootstrap.history.genesis.url' "$receipt")" "$(jq -er '.bootstrap.history.genesis.runtime_sha256' "$receipt")" "$home/genesis/bin/inferenced"
while IFS=$'\t' read -r name url sha; do
  install -d -m 0755 "$home/upgrades/$name/bin"
  download_runtime "$url" "$sha" "$home/upgrades/$name/bin/inferenced"
done < <(jq -r '.bootstrap.history.upgrades[] | [.name,.url,.runtime_sha256] | @tsv' "$receipt")
[[ ! -e "$home/current" && ! -L "$home/current" ]] || { echo 'full-history Cosmovisor current runtime already exists' >&2; exit 1; }
ln -s genesis "$home/current"
printf 'PASS checked full-history runtime schedule installed without chain-data copy\n'
