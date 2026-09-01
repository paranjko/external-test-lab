#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 [--output FILE] [--source-archive FILE]" >&2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/04-ops/site/world-map.svg"
source_archive=""

while (($#)); do
  case "$1" in
    --output) output="${2:-}"; shift 2 ;;
    --source-archive) source_archive="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$output" ]] || { usage; exit 2; }
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
archive="$source_archive"
if [[ -z "$archive" ]]; then
  archive="$work_dir/ne_50m_land.zip"
  curl -fsSL --retry 3 --retry-delay 1 \
    https://naturalearth.s3.amazonaws.com/50m_physical/ne_50m_land.zip \
    -o "$archive"
fi
[[ -r "$archive" ]] || { echo "cannot read Natural Earth archive: $archive" >&2; exit 2; }
unzip -q "$archive" -d "$work_dir/source"
shape="$(find "$work_dir/source" -type f -name 'ne_50m_land.shp' -print -quit)"
[[ -n "$shape" ]] || { echo 'Natural Earth archive lacks ne_50m_land.shp' >&2; exit 2; }

# Preserve the 50m coastline geometry. The world rectangle establishes the
# exact Plate Carree bounds consumed by L.CRS.EPSG4326; no visual offsets are
# introduced here.
npx --yes mapshaper@0.7.55 "$shape" \
  -proj wgs84 \
  -rename-layers land \
  -rectangle bbox=-180,-90,180,90 name=world \
  -o target=land format=svg width=2000 height=1000 margin=0 fit-extent=world \
  "$output"
sed -i 's/<g id="land">/<g id="land" fill="#292c39" stroke="#73788e" stroke-width="1.3">/' "$output"
printf '\n' >>"$output"
