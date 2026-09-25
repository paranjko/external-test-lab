#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const site = path.join(root, '04-ops', 'site');
const spec = JSON.parse(
  fs.readFileSync(path.join(site, 'status', 'openapi.json'), 'utf8'),
);
const docs = fs.readFileSync(path.join(site, 'status', 'index.html'), 'utf8');
const caddy = fs.readFileSync(
  path.join(root, '04-ops', 'edge-node', 'PublicCaddyfile'),
  'utf8',
);
const packageJson = JSON.parse(
  fs.readFileSync(path.join(root, 'package.json'), 'utf8'),
);

assert.equal(spec.openapi, '3.2.0');
assert.equal(spec.info.title, 'Gonka Community DevNet Status API');
assert.equal(spec.servers[0].url, 'https://gonka-dev.net');
for (const endpoint of [
  '/status/gpus',
  '/status/software',
  '/status/participants',
  '/status/gateway-health',
  '/status/gateway-health.prom',
  '/status/gateway/v1/status',
  '/status/gateway/v1/admission-status',
  '/status/gateway/metrics',
  '/status/telegram-consumer',
]) {
  assert.ok(spec.paths[endpoint], `missing documented endpoint ${endpoint}`);
  assert.ok(spec.paths[endpoint].get, `endpoint must be GET-only: ${endpoint}`);
}
assert.ok(
  !Object.keys(spec.paths).some((endpoint) => endpoint.includes('{')),
  'the transparent Host proxy is not a public status API contract',
);
assert.match(docs, /SwaggerUIBundle/);
assert.match(docs, /\/status\/openapi\.json/);
assert.match(docs, /supportedSubmitMethods: \["get"\]/);
assert.equal(packageJson.devDependencies['swagger-ui-dist'], '5.32.0');
const docsRoute = caddy.indexOf('handle /status/ {');
const dataRoute = caddy.indexOf('@status_data {');
assert.ok(docsRoute >= 0 && dataRoute > docsRoute, 'status docs must precede status proxy');
assert.match(caddy, /handle \/status\/openapi\.json \{/);
assert.match(caddy, /handle \/status\/openapi\.json \{[\s\S]*root \* \/srv\/dai\/edge\/site/);
console.log('PASS public status OpenAPI contract and static documentation');
