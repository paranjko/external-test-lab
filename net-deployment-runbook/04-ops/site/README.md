# Public status site JavaScript

The human-maintained source is in `src/` and uses Flow types

The runbook deploys the generated browser-native files from this directory
They remain formatted and readable, while production deployment does not need
Babel, Flow or a Node.js runtime

- `app.js` renders participants, the validator map and gateway health
- `gateway-state.js` converts gateway and probe payloads into public states
- `software-versions.js` formats component versions
- `config.js` documents the rendered configuration contract

Validate the Flow source and confirm that generated files are current:

```sh
make site-js-check
```

After editing a source file, format it and regenerate the browser files:

```sh
npx --yes prettier@3.6.2 --write 04-ops/site/src/*.js
make site-js
```

## Validator-map basemap provenance

`world-map.svg` is a local land-only, equirectangular schematic for approximate
public-IP validator locations. It is not a navigation map and has no political
borders, map-provider runtime dependency, API key, or remote tile request.

The local renderer is Leaflet 1.9.4 under its BSD-2-Clause license. `make
site-vendor` installs the locked build dependency and copies its distribution
to the ignored `vendor/leaflet/` build directory. It uses `L.CRS.EPSG4326`
and `world-map.svg` as an image overlay. It does not create a tile layer or
make map-provider requests.

Known DevNet aliases use operator-approved coarse regional points. Dynamic
participants retain their raw GeoIP observation and are displayed only when
that point is on the local land geometry or can be moved to nearby land within
80 km; otherwise their map marker is omitted. Popup content identifies the
source, raw position, observation time and any display correction.

- Dataset: Natural Earth `50m Land`, retrieved 2026-08-31.
- Canonical dataset page: <https://www.naturalearthdata.com/downloads/50m-physical-vectors/50m-land/>.
- Source archive: <https://naturalearth.s3.amazonaws.com/50m_physical/ne_50m_land.zip>.
- Terms: <https://www.naturalearthdata.com/about/terms-of-use/> – Natural Earth
  data is public domain.
- Source archive SHA-256: `0b8e670cf80dce9cbebe2a193bc44ba5602758c22e1fa603980553646d7ff162`.
- Output geographic contract: north-up Plate Carree longitude `[-180, 180]`,
  latitude `[-90, 90]`, rendered in the exact `2000×1000` (`2:1`) viewport
  with no visual coordinate offsets. Leaflet uses this image as a local
  EPSG:4326 overlay, so its geographic bounds and marker positions stay
  aligned without stretching the world to the responsive container.
- Rebuild: `bash scripts/build-world-map.sh`. The generator pins `mapshaper`
  0.7.55 and deliberately applies no simplification, so small coastal regions
  remain visible. It accepts `--source-archive` for offline reproduction.
- Committed SVG SHA-256: `49200cfcf6b59454f32711aaf2ff25cad2352baecafa4196fe14b4042984c5fd`.

The browser fixture allows only the SVG root, one land group and path elements;
it rejects script, handlers, external references, foreign objects, embedded
raster content and unsafe XML declarations. It does not impose an arbitrary
size limit on the coastal geometry.
