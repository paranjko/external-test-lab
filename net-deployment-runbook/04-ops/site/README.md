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

## Local view

Build and serve the current static site only on loopback:

```sh
make -C net-deployment-runbook site-serve
```

Open <http://127.0.0.1:8080/>. The markup, styles and JavaScript come from the checkout; `config.js` and `/status/*` are read from `https://gonka-dev.net`. Override `site_serve_port` when that port is in use, or use a preview as the public data source:

```sh
make -C net-deployment-runbook site-serve \
  site_serve_origin=https://preview.gonka-dev.net/215
```

The local server never changes a Host or the public site.

## Public network selection

`?chainId=<id>` and `#chainId=<id>` ask `/status/network?chainId=<id>` to
observe the bootstrap at `https://gonka-dev.net/<id>/bootstrap.json`. The
browser does not fetch bootstrap or peer endpoints itself.

The observer returns only public evidence: bootstrap seeds and discovered P2P
peers, RPC identity/height/sync state, component versions, MLNode entries
published by `/v1/versions`, and DevShard health. A selected network has no
inherited DevNet model, GPU, participant voting power, PoC, gateway, or
geographic inventory. Those values remain `Not reported` unless a public
endpoint proves them.

The first selected-network request may return `202 observation_pending`. It
only queues the observation; the periodic worker fetches the bootstrap and
updates the cache. This keeps a browser request bounded and prevents it from
starting unbounded peer scans.

## Static publication

`make publish-site-release` copies files into the existing Caddy bind mount without restarting or reloading Caddy, so site delivery does not interrupt the shared HTTPS listener used by bootstrap publication

The publisher preserves the host's `config.js` and `preview/` directory, it does not apply pending Compose or Caddy configuration changes

`make test-site-publisher` checks the executed publication commands and `make edge-integration` verifies new site bytes, unchanged bootstrap bytes and unchanged Caddy container identity in a disposable local container

The static publisher does not update or restart the production network observer

Before site publication, CI verifies that `/status/network` serves a fresh full chain snapshot and `/status/network/ws` streams its current snapshot envelope

If this capability check fails, the static release is not published

Updating the observer adapter and its Caddy and systemd wiring requires a separate, explicitly scoped operator upgrade

## Preview participant inventory

Preview identifies participants by their registry account address, not by an IP, domain name or operator alias, so multiple accounts may share an endpoint

The inventory receipt retains each registered endpoint and its policy result, public IPv4 addresses and domains resolving only to public IPv4 addresses are eligible, while invalid, private, unresolved or unsupported endpoints retain an exclusion reason without failing the complete build

Eligibility is not a serving-health check or permission to open a proxy route, the build never requests participant endpoints and the trusted proxy retains its separate fixed service routes and connection-time DNS checks

The preview observer reads participant identities and hardware from the chain registry independently of the service-route inventory

The trusted inventory builder collects GeoIP into a separate location catalog for all eligible participant endpoints, including IP addresses, without adding proxy routes

The map uses this catalog when a live observation has no coordinates, location lookup failures remain recorded as `geo_error` in the inventory receipt

The observation guard accepts multiple public IPv4 answers for the GeoIP provider, checks every address and pins the connection to one validated address, this guard change requires a separate trusted preview-platform rollout

## Preview cleanup

Closing or merging a same-repository PR, or converting it to draft, removes its isolated preview using the current GitHub PR state

Cleanup does not depend on a PR comment or the latest changed-file list, publication may have succeeded even when comment recording failed

The workflow checks PR state again after waiting for its environment, a reopened PR or one marked ready for review keeps its preview

The trusted controller reloads only preview routes and removes the selected PR's labelled backend, network, releases and staging files, it does not install assets, rebuild images or restart shared services

Repeated cleanup and cleanup of a PR without a preview are safe, interrupted cleanup can find its remaining backend by labels

The workflow requires HTTP 404 for the removed frontend, build metadata and status route, connection failures, redirects and HTTP 5xx do not count as successful removal

The `preview` account, its rootless Docker runtime and running preview Caddy must already be provisioned, cleanup does not repair or provision the host

For an operator-authorized retry, first verify the PR is still closed or draft, then use the existing publisher configuration:

```sh
make -C net-deployment-runbook remove-isolated-site-preview preview_number=PR_NUMBER preview_revision=FULL_HEAD_SHA
make -C net-deployment-runbook verify-removed-site-preview-live preview_number=PR_NUMBER
```

`make test-preview-lifecycle` exercises removal, repeated removal and interruption recovery with real disposable containers while checking that another preview and shared services stay unchanged

## Browser regression

`make test-validator-map` checks all 17 viewport sizes, including responsive
breakpoints, Host-card geometry, keyboard access, map projection and fullscreen
popups. The overlapping-marker pointer scenario selects its own desktop and
mobile dimensions and runs once per invocation. Each viewport prints its
duration; the JSON report remains in `map_evidence_dir`.

PNG captures are optional diagnostics, not image-comparison assertions. Enable
them for visual inspection:

```sh
GDC_MAP_FIXTURE_SCREENSHOTS=1 make test-validator-map
```

To investigate a specific viewport, set `GDC_MAP_FIXTURE_VIEWPORTS=390x844`.
Keep the full matrix for acceptance; the filter is only a debugging aid.

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
