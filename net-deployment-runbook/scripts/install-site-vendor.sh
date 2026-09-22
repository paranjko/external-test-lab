#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/node_modules/leaflet/package.json"
swagger_package="$root/node_modules/swagger-ui-dist/package.json"
destination="$root/04-ops/site/vendor/leaflet"
swagger_destination="$root/04-ops/site/vendor/swagger-ui"

if [[ ! -r "$package" || ! -r "$swagger_package" ]] || ! node -e '
const leaflet = require(process.argv[1]);
const swagger = require(process.argv[2]);
process.exit(leaflet.version === "1.9.4" && swagger.version === "5.32.0" ? 0 : 1);
' "$package" "$swagger_package"; then
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

swagger_source="$root/node_modules/swagger-ui-dist"
for file in swagger-ui.css swagger-ui-bundle.js swagger-ui-standalone-preset.js; do
  [[ -r "$swagger_source/$file" ]] || {
    echo "Swagger UI asset is unavailable after dependency installation: $file" >&2
    exit 1
  }
done
install -d -m 0755 "$swagger_destination"
install -m 0644 \
  "$swagger_source/swagger-ui.css" \
  "$swagger_source/swagger-ui-bundle.js" \
  "$swagger_source/swagger-ui-standalone-preset.js" \
  "$swagger_destination/"
install -m 0644 "$swagger_source/LICENSE" "$swagger_destination/LICENSE"
