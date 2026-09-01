#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/node_modules/leaflet/package.json"
destination="$root/04-ops/site/vendor/leaflet"

if [[ ! -r "$package" ]] || ! node -e '
const leaflet = require(process.argv[1]);
process.exit(leaflet.version === "1.9.4" ? 0 : 1);
' "$package"; then
  (cd "$root" && npm ci --ignore-scripts --no-audit --no-fund)
fi

source="$root/node_modules/leaflet/dist"
[[ -r "$source/leaflet.js" && -r "$source/leaflet.css" ]] || {
  echo 'Leaflet distribution is unavailable after dependency installation' >&2
  exit 1
}
install -d -m 0755 "$destination"
rsync -a --delete "$source/" "$destination/"
install -m 0644 "$root/node_modules/leaflet/LICENSE" "$destination/LICENSE"
