#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
phase="$ROOT/scripts/phase-bifrost.sh"
bash -n "$phase" "$ROOT/gdc.sh"
grep -Fq 'ops-bifrost-$2' "$ROOT/gdc.sh"
grep -Fq 'ops bifrost preview or apply' "$phase"
grep -Fq 'GDC_BIFROST_APPROVED_PREVIEW_SHA256' "$phase"
grep -Fq 'Bifrost state changed after preview; refusing stale apply' "$phase"
grep -Fq 'delta_fields=0 no-change' "$phase"
grep -Fq 'gdc-bifrost-state/1' "$phase"
grep -Fq 'could not determine whether Bifrost is absent before empty-state preview' "$phase"
grep -Fq 'refusing synthetic empty-state preview' "$phase"
grep -Fq 'python3 /srv/dai/ops/bifrost-provision.py --preview' "$phase"
grep -Fq -- '--apply --expected-sha256 $bifrost_expected_state_sha' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'exec "$ROOT/scripts/phase-ops.sh" bifrost' "$phase"
grep -Fq 'upstream="http://127.0.0.1:$port"' "$phase"
grep -Fq 'BIFROST_GONKA_BASE_URL=http://127.0.0.1:$gateway_port' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'BIFROST_EDGE_TOKEN' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'bifrost-edge.env' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'bifrost-edge' "$ROOT/04-ops/compose.yaml"
grep -Fq "BIFROST_OPTION=''" "$ROOT/scripts/phase-ops.sh"
grep -Fq 'handle /v1/*' "$ROOT/04-ops/Caddyfile"
grep -Fq 'handle /anthropic/*' "$ROOT/04-ops/Caddyfile"
grep -Fq 'handle /genai/*' "$ROOT/04-ops/Caddyfile"

# Exercise the extracted preview helpers with a fake SSH transport.  The
# static checks above keep the intended guard discoverable; this proves a
# locally answering, unmanaged Bifrost cannot fall through to the synthetic
# empty-store receipt.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
awk '/^synthetic_empty_preview\(\)/,/^if \[\[ "\$action" == preview \]\]; then/' "$phase" \
  | sed '$d' >"$tmp/preview-functions.sh"
cat >"$tmp/ssh" <<'SSH'
#!/usr/bin/env bash
if [[ "$*" == *'sudo test -r /srv/dai/ops/bifrost.env'* ]]; then
  exit 1
fi
if [[ "$*" == *'curl -sS --connect-timeout 2'* ]]; then
  printf '%s' "${TEST_BIFROST_HTTP_CODE:?}"
  exit 0
fi
exit 97
SSH
chmod +x "$tmp/ssh"
cat >"$tmp/run-preview" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
die() { echo "error: $*" >&2; exit 1; }
source "$1"
remote_preview
SH
chmod +x "$tmp/run-preview"

if PATH="$tmp:$PATH" TEST_BIFROST_HTTP_CODE=200 GATEWAY_NODE=fixture-host \
  image=fixture-image provider=fixture-provider model=fixture-model upstream=http://127.0.0.1:12345 \
  "$tmp/run-preview" "$tmp/preview-functions.sh" >"$tmp/answered.out" 2>"$tmp/answered.err"
then
  echo 'a reachable unmanaged Bifrost produced a synthetic empty-state preview' >&2
  exit 1
fi
grep -Fq 'refusing synthetic empty-state preview' "$tmp/answered.err"

PATH="$tmp:$PATH" TEST_BIFROST_HTTP_CODE=000 GATEWAY_NODE=fixture-host \
  image=fixture-image provider=fixture-provider model=fixture-model upstream=http://127.0.0.1:12345 \
  "$tmp/run-preview" "$tmp/preview-functions.sh" >"$tmp/empty.json"
jq -e '.current.bootstrap == "empty" and .delta == ["bootstrap", "provider", "provider_key"]' \
  "$tmp/empty.json" >/dev/null
printf 'PASS Bifrost deployment binds apply to a redacted current-state preview\n'
