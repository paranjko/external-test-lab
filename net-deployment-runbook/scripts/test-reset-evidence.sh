#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

! grep -F 'rm -rf "$STATE" "$ROOT/artifacts/accounts" "$ROOT/artifacts/genesis" "$ROOT/artifacts/runs"' "$ROOT/scripts/phase-reset.sh"
grep -Fq 'Prior run evidence: preserved under artifacts/runs' "$ROOT/scripts/phase-reset.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

printf '\x89PNG\r\n\x1a\nfixture' >"$fixture/public-reset-state.png"
printf '# DevNet reset preservation: PASS\n' >"$fixture/verdict.md"
cat >"$fixture/pre-reset.env" <<'EOF'
reset_started_at=2026-08-06T10:00:00Z
pre_reset_chain_id=gonka-devnet-community
pre_reset_genesis_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf 'fixture  artifacts/runs/example/verdict.md\n' >"$fixture/artifacts-runs.before.sha256"
cp "$fixture/artifacts-runs.before.sha256" "$fixture/artifacts-runs.after.sha256"
for host in gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; do
  printf 'image sha256:fixture\nhf-cache/model 1 2\n' >"$fixture/$host.before"
  cp "$fixture/$host.before" "$fixture/$host.after"
done

reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml

printf 'changed\n' >>"$fixture/gdc-node2.after"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted a changed manifest\n' >&2
  exit 1
fi
cp "$fixture/gdc-node2.before" "$fixture/gdc-node2.after"

printf 'changed evidence\n' >>"$fixture/artifacts-runs.after.sha256"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted changed lifecycle evidence\n' >&2
  exit 1
fi
cp "$fixture/artifacts-runs.before.sha256" "$fixture/artifacts-runs.after.sha256"

rm "$fixture/gdc-node4.after"
if reset_evidence_bundle_is_valid "$fixture" \
  gdc-node0 gdc-node1 gdc-node2 gdc-node4 gdc-node4-ml; then
  printf 'reset evidence accepted a missing manifest\n' >&2
  exit 1
fi

printf 'PASS reset evidence bundle contract\n'
