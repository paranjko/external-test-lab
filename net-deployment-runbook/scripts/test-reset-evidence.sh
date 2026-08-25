#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

! grep -F 'rm -rf "$STATE" "$GDC_HOME/accounts" "$GDC_HOME/genesis" "$GDC_HOME/runs"' "$ROOT/scripts/phase-reset.sh"
grep -Fq '"$GDC_HOME/mnemonics"' "$ROOT/scripts/phase-reset.sh"
grep -Fq '! -name .lifecycle.lock -exec rm -rf -- {} +' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'Prior run evidence: preserved under $GDC_HOME/runs' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'GDC_RESET_MANAGED_ALIASES' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'reset --hosts requires a comma-separated SSH alias list' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'reset --hosts must include the Genesis node' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'reset-hosts.txt' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'reset-hosts.txt' "$ROOT/scripts/phase-audit-lifecycle.sh"
if grep -Fq 'reset_nodes=("${GDC_NODES[@]}")' "$ROOT/scripts/phase-audit-lifecycle.sh"; then
  echo 'lifecycle audit must not infer reset scope for legacy evidence' >&2
  exit 1
fi
grep -Fq 'managed_project' "$ROOT/scripts/reset-remote-host.sh"
grep -Fq '"/srv/dai/deploy/$alias" "/srv/dai/$alias"' "$ROOT/scripts/reset-remote-host.sh"
grep -Fq 'gdc-poc-winddown-watch@$alias.service' "$ROOT/scripts/reset-remote-host.sh"
grep -Fq 'GDC_RESET_PRESERVE_PUBLIC_EDGE=true' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'GDC_SITE_KEEP_CADDY=true' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'public observability was restored' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'GDC_PUBLIC_EDGE_VERIFY=false "$ROOT/scripts/phase-ops.sh" edge' "$ROOT/scripts/phase-reset.sh"
grep -Fq '/srv/dai/hf-cache' "$ROOT/scripts/phase-reset.sh"
grep -Fq '!expectResetState && state.nodes.length < 1' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq 'state.mapValidators !== 0' "$ROOT/scripts/capture-homepage-viewport.mjs"
capture_line="$(grep -n 'capture-homepage-viewport.mjs' "$ROOT/scripts/phase-reset.sh" | cut -d: -f1)"
ready_line="$(grep -n 'public status site is unavailable after reset' "$ROOT/scripts/phase-reset.sh" | cut -d: -f1)"
[[ "$capture_line" =~ ^[0-9]+$ && "$ready_line" =~ ^[0-9]+$ && "$capture_line" -gt "$ready_line" ]] || {
  echo 'reset must wait for public site readiness before capturing browser evidence' >&2
  exit 1
}
if grep -Fq 'find /srv/dai -mindepth 1 -maxdepth 1' "$ROOT/scripts/reset-remote-host.sh"; then
  echo 'reset must not sweep the operator-managed /srv/dai directory' >&2
  exit 1
fi
if grep -Fq 'rm -rf -- /srv/dai.previous.* /tmp/gdc-*' "$ROOT/scripts/reset-remote-host.sh"; then
  echo 'reset must not delete broad operator paths outside the deployment inventory' >&2
  exit 1
fi

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

printf '\x89PNG\r\n\x1a\nfixture' >"$fixture/public-reset-state.png"
printf '# DevNet reset preservation: PASS\n' >"$fixture/verdict.md"
cat >"$fixture/pre-reset.env" <<'EOF'
reset_started_at=2026-08-06T10:00:00Z
pre_reset_chain_id=gonka-devnet-community
pre_reset_genesis_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf 'fixture  runs/example/verdict.md\n' >"$fixture/runs.before.sha256"
cp "$fixture/runs.before.sha256" "$fixture/runs.after.sha256"
for host in gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; do
  printf 'image sha256:fixture\nhf-cache/model 1 2\n' >"$fixture/$host.before"
  cp "$fixture/$host.before" "$fixture/$host.after"
done

reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml

mv "$fixture/runs.before.sha256" "$fixture/artifacts-runs.before.sha256"
mv "$fixture/runs.after.sha256" "$fixture/artifacts-runs.after.sha256"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted an obsolete artifact layout\n' >&2
  exit 1
fi
mv "$fixture/artifacts-runs.before.sha256" "$fixture/runs.before.sha256"
mv "$fixture/artifacts-runs.after.sha256" "$fixture/runs.after.sha256"

printf 'changed\n' >>"$fixture/gdc-node2.after"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted a changed manifest\n' >&2
  exit 1
fi
cp "$fixture/gdc-node2.before" "$fixture/gdc-node2.after"

printf 'changed evidence\n' >>"$fixture/runs.after.sha256"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted changed lifecycle evidence\n' >&2
  exit 1
fi
cp "$fixture/runs.before.sha256" "$fixture/runs.after.sha256"

rm "$fixture/gdc-node4.after"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted a missing manifest\n' >&2
  exit 1
fi

printf 'PASS reset evidence bundle contract\n'
