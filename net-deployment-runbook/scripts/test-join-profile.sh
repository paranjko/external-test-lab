#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/scripts/join-profile.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/observation.json" <<'EOF'
{"schema_version":1,"kind":"gdc-network-observation","network_state_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","runtime":{"core":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"dapi":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"},"devshard_approved_versions":[{"name":"v3","url":"https://example.test/v3.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},{"name":"v4","url":"https://example.test/v4.zip","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]},"result":{"state":"ready","reason":"none"}}
EOF
cat >"$tmp/spec.json" <<'EOF'
{"network":{"chain_id":"gonka-fixture","genesis_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","bootstrap_sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"target":{"node_name":"gdc-node9","public_host":"node9.example.test","public_p2p_address":"tcp://node9.example.test:5000","platform":"linux-amd64"},"deployment":{"gdc_source_commit":"ffffffffffffffffffffffffffffffffffffffff","data_layout":"gdc-data-layout/v2"},"components":{"core":{"observed":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"expected_runtime":{"version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"installation":{"mode":"image_plus_cosmovisor","image":{"repository":"example/core","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"binary":{"url":"https://example.test/core.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},"mapping_source":{"kind":"qualified_catalog","id":"fixture","definition_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},"dapi":{"observed":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"},"expected_runtime":{"version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"},"installation":{"mode":"qualified_image","image":{"repository":"example/dapi","digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"binary":{"url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15-post3/decentralized-api-amd64.zip","sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}},"mapping_source":{"kind":"qualified_catalog","id":"fixture","definition_sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}},"devshard":{"approved_versions":[{"name":"v3","url":"https://example.test/v3.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},{"name":"v4","url":"https://example.test/v4.zip","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]}},"state_acquisition":{"mode":"native_p2p_state_sync","providers":["0123456789abcdef0123456789abcdef01234567@tcp://node0.example.test:5000","89abcdef0123456789abcdef0123456789abcdef@tcp://node1.example.test:5000"],"minimum_providers":2},"identity":{"mode":"generate","stable_identity_layout":"gdc-identity-layout/v2"},"activation_policy":{"application_required_for_complete":true,"signer_allowed_in_profile":false,"old_signer_fence_required":false}}
EOF

jq '.deployment.host_envelope = {
  tmkms_image:"example/tmkms@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  postgres_image:"example/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  edge_api_image:"example/edge@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  versiond_image:"example/versiond@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  proxy_image:"example/proxy@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  explorer_image:"example/explorer@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  mlnode_image:"example/mlnode@sha256:1111111111111111111111111111111111111111111111111111111111111111",
  mlnode_proxy_image:"example/mlnode-proxy@sha256:2222222222222222222222222222222222222222222222222222222222222222",
  caddy_image:"example/caddy@sha256:5555555555555555555555555555555555555555555555555555555555555555",
  grafana_image:"example/grafana@sha256:6666666666666666666666666666666666666666666666666666666666666666",
  node_exporter_image:"example/node-exporter@sha256:7777777777777777777777777777777777777777777777777777777777777777",
  cadvisor_image:"example/cadvisor@sha256:8888888888888888888888888888888888888888888888888888888888888888",
  host_stack:{repository:"gonka-ai/gonka",commit:"ce33c851282b8f4c0f63d78d46ddd4d8bb248207",compose_sha256:"9999999999999999999999999999999999999999999999999999999999999999",api_image:"example/api@sha256:9999999999999999999999999999999999999999999999999999999999999999"},
  dashboard_port:5173,
  edge_api_compose_profile:"edge",
  edge_api_service_name:"edge-api",
  model_id:"Qwen/Qwen3-0.6B",
  model_revision:"3333333333333333333333333333333333333333",
  mlnode_context_length:32768,
  mlnode_max_num_seqs:8,
  mlnode_gpu_memory_utilization:"0.9",
  mlnode_dtype:"auto",
  mlnode_tensor_parallel_size:1,
  join_effective_epochs:4,
  join_effective_timeout_seconds:7200,
  mapping_source:{kind:"qualified_catalog",id:"fixture",definition_sha256:"4444444444444444444444444444444444444444444444444444444444444444"}
}' "$tmp/spec.json" >"$tmp/spec.with-envelope.json"
mv "$tmp/spec.with-envelope.json" "$tmp/spec.json"
jq '.network.bootstrap_url = "https://gonka-dev.net/gonka-fixture/bootstrap.json" | .seeds = {usable:[{seed_index:0,status:"usable",reason:"none"}],unavailable:[]} | del(.components.devshard) | .state_acquisition = {mode:"pending",providers:[],minimum_providers:0}' "$tmp/spec.json" >"$tmp/spec.pending.json"
mv "$tmp/spec.pending.json" "$tmp/spec.json"

"$TOOL" create --observation "$tmp/observation.json" --spec "$tmp/spec.json" --operation new --run-id fixture-run --output "$tmp/profile.json"
"$TOOL" validate "$tmp/profile.json"
id="$(jq -r .profile_id "$tmp/profile.json")"
"$TOOL" create --observation "$tmp/observation.json" --spec "$tmp/spec.json" --operation new --run-id another-run --output "$tmp/profile2.json"
[[ "$(jq -r .profile_id "$tmp/profile2.json")" == "$id" ]]
jq '.spec.components.core.installation.binary.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$tmp/profile.json" >"$tmp/tampered.json"
if "$TOOL" validate "$tmp/tampered.json" >"$tmp/tampered.out" 2>"$tmp/tampered.err"; then echo 'tampered Join Profile was accepted' >&2; exit 1; fi
grep -Fq 'profile_id does not bind' "$tmp/tampered.err"
jq '.valid_until = "2000-01-01T00:00:00Z"' "$tmp/profile.json" >"$tmp/expired.json"
if "$TOOL" validate "$tmp/expired.json" >"$tmp/expired.out" 2>"$tmp/expired.err"; then echo 'expired Join Profile was accepted' >&2; exit 1; fi
grep -Fq 'profile has expired' "$tmp/expired.err"
"$TOOL" validate --allow-expired "$tmp/expired.json"
jq 'del(.spec.deployment.host_envelope)' "$tmp/profile.json" >"$tmp/missing-envelope.json"
if "$TOOL" validate "$tmp/missing-envelope.json" >"$tmp/missing-envelope.out" 2>"$tmp/missing-envelope.err"; then echo 'Join Profile without Host envelope was accepted' >&2; exit 1; fi
grep -Fq 'invalid closed v1 shape' "$tmp/missing-envelope.err"
if "$TOOL" create --observation "$tmp/observation.json" --spec "$tmp/spec.json" --operation restore --run-id fixture-run --output "$tmp/restore.json" >"$tmp/restore.out" 2>"$tmp/restore.err"; then echo 'restore accepted generate identity' >&2; exit 1; fi
grep -Fq 'not bound exactly' "$tmp/restore.err"
printf 'PASS Join Profile is observation-bound, deterministic and tamper-evident\n'
