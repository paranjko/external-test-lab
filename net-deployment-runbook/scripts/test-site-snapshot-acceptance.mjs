#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const site = new URL('../04-ops/site/', import.meta.url);
const capture = fileURLToPath(new URL('./capture-homepage-viewport.mjs', import.meta.url));
const outputRoot = await mkdtemp(join(tmpdir(), 'gdc-snapshot-acceptance-'));
const output = join(outputRoot, 'preview.png');
const nodeId = 'a'.repeat(40);
const validator = 'B'.repeat(40);
const requests = [];
const websocketClients = new Set();
const locations = [
  ['node0.gonka-dev.net', 39.0997282, -94.5785689],
  ['node5.gonka-dev.net', 39.0997282, -94.5785689],
  ['node11.gonka-dev.net', 39.1141718, -94.6274601],
  ['node2.gonka-dev.net', 52.374028, 4.8896881],
  ['node3.gonka-dev.net', 51.5127883, -0.0918432],
  ['31.192.105.46', 55.7520384, 37.6178147],
].map(([publicHost, latitude, longitude]) => ({publicHost,
  geo: {latitude, longitude, source: 'ip-geolocation', accuracy: 'city'}}));
const snapshot = () => {
  const now = new Date().toISOString();
  const result = {
    schema_version: 1,
    chain_id: 'fixture-chain',
    observed_at: now,
    nodes: [{
      node_id: nodeId,
      node_name: 'node0',
      dapi_url: 'https://node0.gonka-dev.net',
      active: true,
      components: {
        chain_rpc: { state: 'observed', p2p_node_id: nodeId, chain_id: 'fixture-chain', validator_address: validator,
          validator_voting_power: '72', latest_block_height: 1050, latest_block_time: now, observed_at: now, catching_up: false },
        peers: { state: 'observed', count: 7 },
        versions: { state: 'observed', observed_at: now, api_version: { version: 'v0.2.16', commit: 'a'.repeat(40) },
          node_version: { version: 'v0.2.16', commit: 'a'.repeat(40) }, mlnodes: [] },
        inferenced: { state: 'observed', observed_at: now, version: 'v0.2.16', commit: 'a'.repeat(40) },
        models: { state: 'observed', models: [{ id: 'fixture-model' }] },
        devshard: { state: 'observed', observed_at: now, runtimes: [{ name: 'v6', status: 'running', sha256: 'c'.repeat(64) }],
          stats: { state: 'observed', observed_at: now, protocol_version: 'v6', current_epoch_id: 7, cached_at: Date.now() / 1000,
            cache_ttl_seconds: 60, active_escrows: [], shards: [] } },
      },
    }],
    chain: {
      state: 'observed', observed_at: now,
      reference: { node_id: nodeId, height: 1050 },
      validators: [{ address: validator, voting_power: '72' }],
      participants: [{ address: 'gonka1fixtureaccount', inference_url: 'https://node0.gonka-dev.net', status: 'ACTIVE' }],
      hardware_nodes: [{ address: 'gonka1fixtureaccount', nodes: [{ local_id: 'fixture', host: 'inference', port: '8080',
        version: '3.0.16', hardware: [{ type: 'Fixture GPU | 24GB', count: 1 }] }] }],
      approved_devshards: [{ name: 'v6', sha256: 'c'.repeat(64) }],
      activity: {
        epoch: { latest_epoch: { index: '7', poc_start_block_height: '1000', end_height: '1100', blocks_remaining: '50' },
          estimated_remaining_seconds: 100, block_interval_seconds: 2 },
        cpoc: { state: 'observed', active: false, recent_events_state: 'observed', recent_events: [] },
        finalized_epoch: { state: 'unavailable' }, commits: { commits: [] }, votes: { poc_validation: [] },
      },
    },
  };
  const template = result.nodes[0];
  for (const [index, location] of locations.entries()) {
    if (index === 0) continue;
    const node = structuredClone(template);
    node.node_id = String(index).repeat(40);
    node.node_name = location.publicHost.split('.')[0];
    node.dapi_url = `https://${location.publicHost}`;
    node.components.chain_rpc.p2p_node_id = node.node_id;
    node.components.chain_rpc.validator_address = String(index).repeat(40);
    result.nodes.push(node);
    result.chain.validators.push({address: node.components.chain_rpc.validator_address, voting_power: '72'});
    const address = `gonka1fixture${index}`;
    result.chain.participants.push({address, inference_url: node.dapi_url, status: 'ACTIVE'});
    result.chain.hardware_nodes.push({address, nodes: [{local_id:'fixture', host:'inference', port:'8080',
      version:'3.0.16', hardware:[{type:'Fixture GPU | 24GB', count:index === 2 ? 2 : 1}]}]});
  }
  return result;
};
const gatewayUnavailable = JSON.stringify({ error: 'preview_gateway_status_unavailable' });
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url, 'http://fixture').pathname;
  requests.push(pathname);
  response.setHeader('Cache-Control', 'no-store');
  if (pathname === '/config.js') {
    response.setHeader('Content-Type', 'application/javascript');
    response.end(`window.GDC_CONFIG=${JSON.stringify({
      chainId: 'fixture-chain', model: 'old-model', gatewayNode: 'node0', statusBase: '/status',
      grafanaNetwork: 'https://grafana.gonka-dev.net/d/gdc-network/?kiosk',
      grafanaInference: 'https://grafana.gonka-dev.net/d/gdc-inference/?kiosk',
      grafanaChain: 'https://grafana.gonka-dev.net/d/gdc-chain/?kiosk',
      publicBootstrap: false, nodes: [],
      nodeCatalog: [{ name: 'node0', statusAlias: 'node0', publicHost: 'node0.gonka-dev.net' }],
      locationCatalog: locations,
    })}`);
  } else if (pathname === '/status/network') {
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify(snapshot()));
  } else if (pathname === '/status/gateway/v1/status' || pathname === '/status/gateway-health' || pathname === '/status/gateway/v1/admission-status') {
    response.writeHead(503, { 'Content-Type': 'application/json' });
    response.end(gatewayUnavailable);
  } else if (pathname.startsWith('/status/')) {
    response.writeHead(404, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ error: 'unexpected_status_route', path: pathname }));
  } else {
    try {
      const file = pathname === '/' ? 'index.html' : pathname.slice(1);
      if (!/^[A-Za-z0-9_./-]+$/.test(file) || file.includes('..')) throw new Error('unsafe path');
      response.setHeader('Content-Type', file.endsWith('.js') ? 'application/javascript' : file.endsWith('.css') ? 'text/css' : file.endsWith('.svg') ? 'image/svg+xml' : 'text/html');
      response.end(await readFile(new URL(file, site)));
    } catch {
      response.writeHead(404);
      response.end();
    }
  }
});
server.on('upgrade', (request, socket) => {
  const pathname = new URL(request.url, 'http://fixture').pathname;
  requests.push(pathname);
  if (pathname !== '/status/network/ws' || !request.headers['sec-websocket-key']) {
    socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    return;
  }
  websocketClients.add(socket);
  socket.on('close', () => websocketClients.delete(socket));
  const accept = createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const payload = Buffer.from(JSON.stringify({ type: 'network_snapshot', snapshot: snapshot() }));
  const length = payload.length;
  const header = length < 126
    ? Buffer.from([0x81, length])
    : length <= 0xffff
      ? Buffer.from([0x81, 126, (length >> 8) & 0xff, length & 0xff])
      : Buffer.from([0x81, 127, 0, 0, 0, 0, (length >>> 24) & 0xff, (length >>> 16) & 0xff, (length >>> 8) & 0xff, length & 0xff]);
  socket.write(Buffer.concat([header, payload]));
});

let child;
try {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const env = {
    ...process.env,
    GDC_EXPECT_NETWORK_SNAPSHOT: 'true',
    GDC_EXPECT_STATUS_PREFIX: '/status/',
    GDC_EXPECT_GATEWAY_STATE: 'UNAVAILABLE',
    GDC_EXPECT_GATEWAY_READY: 'false',
    GDC_EXPECT_RESET_STATE: 'false',
    GDC_CHECK_MAP_FULLSCREEN: 'false',
    GDC_EXPECT_CARD_COUNT: '0',
    GDC_EXPECT_NODE_STATES: '',
    GDC_EXPECT_SITE_REVISION: '',
    GDC_EXPECT_APP_DIGEST: '',
    GDC_EXPECT_GITHUB_HREF: '',
  };
  child = spawn(process.execPath, [capture, url, '1280', '900', output, '0', '0'], {
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
  child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
  const exitCode = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', resolve);
  });
  assert.equal(exitCode, 0, `capture helper rejected the expected preview contract\nstdout:\n${stdout}\nstderr:\n${stderr}`);
  const report = JSON.parse(await readFile(`${output}.json`, 'utf8'));
  assert.equal(report.map.hosts, locations.length, 'all observed nodes need map locations independently of service routes');
  assert.equal(report.map.groups, 4, 'Kansas City nodes must share one displayed square');
  assert(report.map.markers.some(marker => marker.count === 3 && marker.gpuCount === 4), 'EM29 must include node0, node5 and node11 with four GPUs');
  assert(report.nodes.some(node => node.name === '31.192.105.46'), 'IPv4 must not be truncated to its first octet');
  assert.deepEqual(report.screenshot_scroll, { x: 0, y: 0 }, 'capture helper did not honor top-of-page screenshot position');
  assert(requests.includes('/status/network/ws'), 'fixture did not exercise the live network WebSocket');
  for (const path of ['/status/gateway/v1/status', '/status/gateway-health', '/status/gateway/v1/admission-status']) {
    assert(requests.includes(path), `fixture did not exercise ${path}`);
  }
  console.log('PASS snapshot browser acceptance allows only the explicit preview gateway 503 contract');
} finally {
  if (child && child.exitCode === null) child.kill('SIGTERM');
  for (const socket of websocketClients) socket.destroy();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(outputRoot, { recursive: true, force: true });
}
