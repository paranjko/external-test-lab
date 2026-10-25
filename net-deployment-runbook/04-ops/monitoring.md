# Monitoring independent of gateway placement

`gdc ops monitoring` reads `.env` from the selected `GDC_HOME` operator root.
Set `GDC_MONITORING_HOST` to the collector's public DNS name; Genesis retains
this identity independently of its consensus seed. Host exporter ingress must
allow that collector, not necessarily the Genesis Host.

Optional inventory settings:

- `GDC_MONITORING_ONLY_NODES`: space-separated aliases with host/container
  metrics but no consensus or participant-endpoint targets.
- `GDC_MONITORING_NO_GPU_HOSTS`: space-separated aliases whose GPU telemetry
  is dropped; their host metrics stay.
- `GDC_MONITORING_RETIRED_HOSTS`: aliases explicitly removed from JOIN discovery.
  A retired alias must not also appear in the configured inventory.
- `GDC_GATEWAY_OBSERVATION_TARGETS`: JSON array of `{id,node,port}` entries.
  IDs are unique uppercase identifiers, nodes are configured SSH aliases,
  ports are local gateway API listeners. Multiple versions can share a Host,
  but each `(node,port)` pair must be unique.

For example:

```sh
GDC_GATEWAY_OBSERVATION_TARGETS='[{"id":"A_V6","node":"gateway-a","port":18146},{"id":"B_V6","node":"gateway-b","port":18146}]'
```

Observation is separate from the legacy `GDC_GATEWAY_METRICS_TARGETS` serving
configuration. It does not move gateways or change their public inference paths.
When configured, it supplies the gateway metrics and status targets, replacing
legacy route/readiness exporters that do not describe these independent runtimes.

The command finds each running participant Caddy by `PUBLIC_HOST`, retains its
existing configuration, and reconciles only a marked observation block in the
top-level `route`. Both directory and single-file bind mounts are supported.
GET `/ops-gateways/<id>/metrics` and `/ops-gateways/<id>/status` are allowed only
from the collector's IPv4 `/32`. Other sources and methods receive 403. This
does not expose gateway administration or credentials.

Caddy validation precedes reload; gateways, validators and ML containers are
not restarted. Receipts beside the existing Caddyfile contain the original
configuration and private validation/reload logs. A reload failure restores the
original configuration. Keep these receipts private: existing Caddy routes may
contain credentials. To roll back, restore `Caddyfile.before` to the original
bind source **without replacing its inode**, then reload that Caddy container.

Static inventory owns configured Hosts. Redundant JOIN entries and explicitly
retired aliases are moved to `prometheus/retired-targets.*`, not discarded.
Unconfigured, non-retired JOIN Hosts remain discoverable. Prometheus historical
series are retained and may remain visible briefly after target reconciliation.

For a Telegram consumer using versioned native gateways, configure its existing
operator environment explicitly, then run `gdc ops consumer telegram apply`:

```sh
GDC_TELEGRAM_A_API_BASE_URL=https://node0.gonka-dev.net/gateway/v6/v1
GDC_TELEGRAM_B_API_BASE_URL=https://node2.gonka-dev.net/gateway/v6/v1
GDC_TELEGRAM_A_STATUS_URL=https://node0.gonka-dev.net/ops-gateways/A_V6/status
GDC_TELEGRAM_B_STATUS_URL=https://node2.gonka-dev.net/ops-gateways/B_V6/status
GDC_TELEGRAM_STATUS_MODE=native
GDC_TELEGRAM_MODEL_ID=Qwen/Qwen3-4B-Instruct-2507
GDC_TELEGRAM_A_METRICS_LABEL=A_V6
GDC_TELEGRAM_B_METRICS_LABEL=B_V6
GDC_TELEGRAM_A_KEY_FILE=/secure/operator/gateway-a-client.key
GDC_TELEGRAM_B_KEY_FILE=/secure/operator/gateway-b-client.key
```

The consumer Host must be allowed to read these source-restricted status routes.
Native mode checks model capacity, access, limiter slots and an active unblocked
Inference-phase runtime before dispatch. It does not fabricate an admission
summary or retry an uncertain dispatched request. Existing credentials and
conversation storage are retained. Without these overrides, the existing
public admission-governor configuration remains the default.
Key-file overrides must reference existing authorized client keys, never admin
or signer credentials. A successful models listing alone does not prove that
the key authorizes inference; deployment verifies a real completion.

Focused checks:

```sh
make test-monitoring-firewall-deployment test-join-monitoring-runtime
bash scripts/test-gateway-metrics-rendering.sh
```
