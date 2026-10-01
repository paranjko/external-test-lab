#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/operator/state/generated/ops"
cp "$ROOT/.env.example" "$tmp/operator/.env"
printf 'DEVSHARD_PORT=18080\nDEVSHARD_MODEL=fixture-model\n' \
  >"$tmp/operator/state/generated/ops/gateway.env"

cat >"$tmp/bin/getent" <<'GETENT'
#!/usr/bin/env bash
[[ "$1" == ahostsv4 ]] || exit 2
printf '192.0.2.10 STREAM fixture\n192.0.2.10 DGRAM\n192.0.2.10 RAW\n'
GETENT
cat >"$tmp/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GDC_TEST_SSH_LOG:?}"
if [[ "$*" == '-G '* ]]; then
  printf 'hostname fixture\n'
  exit 0
fi
if [[ "$*" == *'sudo test -r /srv/dai/ops/bifrost.env'* ]]; then
  [[ "${GDC_TEST_MANAGED_BIFROST:-false}" == true ]] && exit 0
  exit 1
fi
if [[ "${GDC_TEST_MANAGED_BIFROST:-false}" == true && "$*" == *'bifrost-provision.py'* && "$*" == *--preview* ]]; then
  cat "${GDC_TEST_BIFROST_RECEIPT:?}"
  exit 0
fi
if [[ "$*" == *'curl -sS --connect-timeout 2'* ]]; then
  printf '000'
  exit 0
fi
printf 'unexpected fake SSH command: %s\n' "$*" >&2
exit 97
SSH
chmod +x "$tmp/bin/getent" "$tmp/bin/ssh"

if ! GDC_TEST_SSH_LOG="$tmp/ssh.log" PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator" GDC_ENV="$tmp/operator/.env" GDC_RUN_ID=bifrost-preview-launcher \
  "$ROOT/gdc.sh" --release v2026.08.06 ops bifrost preview >"$tmp/stdout" 2>"$tmp/stderr"
then
  cat "$tmp/stderr" >&2
  cat "$tmp/ssh.log" >&2 || true
  exit 1
fi

grep -Fq 'READY bifrost preview host=validator-a delta_fields=3' "$tmp/stdout"
receipt="$tmp/operator/runs/bifrost-preview-launcher/bifrost/preview.json"
jq -e '
  .schema == "gdc-bifrost-state/1" and .host == "validator-a" and
  .current.bootstrap == "empty" and
  .delta == ["bootstrap", "provider", "provider_key"] and
  (.before_sha256 | test("^[0-9a-f]{64}$")) and
  (.desired_sha256 | test("^[0-9a-f]{64}$"))
' "$receipt" >/dev/null
grep -Fq 'sudo test -r /srv/dai/ops/bifrost.env' "$tmp/ssh.log"
grep -Fq 'curl -sS --connect-timeout 2' "$tmp/ssh.log"
if grep -Eq '(docker|rsync|scp|install-ops|bifrost-provision.py --apply)' "$tmp/ssh.log"; then
  echo 'read-only Bifrost preview dispatched a mutating remote command' >&2
  exit 1
fi

if GDC_TEST_SSH_LOG="$tmp/ssh.log" PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator" GDC_ENV="$tmp/operator/.env" GDC_RUN_ID=bifrost-preview-launcher \
  "$ROOT/gdc.sh" --release v2026.08.06 ops bifrost apply >"$tmp/apply.out" 2>"$tmp/apply.err"
then
  echo 'Bifrost apply accepted an unapproved preview receipt' >&2
  exit 1
fi
if ! grep -Fq 'requires GDC_BIFROST_APPROVED_PREVIEW_SHA256' "$tmp/apply.out" "$tmp/apply.err"; then
  cat "$tmp/apply.out" "$tmp/apply.err" >&2
  exit 1
fi

# A converged managed state must consume the exact receipt and return before
# phase-ops. This catches a no-change apply that would otherwise rebuild the
# broker or restart the pinned Bifrost container.
receipt_fixture="$tmp/converged-receipt.json"
jq -n \
  --arg image 'maximhq/bifrost@sha256:5f8215163cea192451f4b2ee5e0b583874ffe9435a5ab733e08c07aaf38ace57' \
  '{schema:"gdc-bifrost-state/1", applied:false,
    current:{bootstrap:"configured",provider:{base_url:"http://127.0.0.1:18080",base_provider_type:"openai",key_count:1,models:["fixture-model"]}},
    desired:{image:$image,provider:"gonka-s",model:"fixture-model",upstream:"http://127.0.0.1:18080"},
    before_sha256:("a" * 64), desired_sha256:("b" * 64), delta:[]}' >"$receipt_fixture"
if ! GDC_TEST_SSH_LOG="$tmp/nochange-ssh.log" GDC_TEST_MANAGED_BIFROST=true GDC_TEST_BIFROST_RECEIPT="$receipt_fixture" PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator" GDC_ENV="$tmp/operator/.env" GDC_RUN_ID=bifrost-nochange-launcher \
  "$ROOT/gdc.sh" --release v2026.08.06 ops bifrost preview >"$tmp/nochange-preview.out" 2>"$tmp/nochange-preview.err"
then
  cat "$tmp/nochange-preview.out" "$tmp/nochange-preview.err" "$tmp/nochange-ssh.log" >&2
  exit 1
fi
nochange_receipt="$tmp/operator/runs/bifrost-nochange-launcher/bifrost/preview.json"
approved_sha="$(sha256sum "$nochange_receipt" | awk '{print $1}')"
GDC_TEST_SSH_LOG="$tmp/nochange-ssh.log" GDC_TEST_MANAGED_BIFROST=true GDC_TEST_BIFROST_RECEIPT="$receipt_fixture" PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator" GDC_ENV="$tmp/operator/.env" GDC_RUN_ID=bifrost-nochange-launcher GDC_BIFROST_APPROVED_PREVIEW_SHA256="$approved_sha" \
  "$ROOT/gdc.sh" --release v2026.08.06 ops bifrost apply >"$tmp/nochange-apply.out" 2>"$tmp/nochange-apply.err"
grep -Fq 'READY bifrost apply host=validator-a delta_fields=0 no-change' "$tmp/nochange-apply.out"
if grep -Eq '(docker|rsync|scp|install-ops|bifrost-provision.py --apply)' "$tmp/nochange-ssh.log"; then
  echo 'converged Bifrost apply dispatched a mutating remote command' >&2
  exit 1
fi

# Exercise the actual launcher and phase-bifrost apply path with a non-empty
# receipt.  The copied runbook replaces only phase-ops at its final handoff so
# this contract can prove receipt-bound dispatch without pretending that a fake
# SSH target is a pinned-image lifecycle environment.  That lifecycle remains
# covered by test-bifrost-pinned-lifecycle.sh.
launcher="$tmp/launcher"
cp -a "$ROOT" "$launcher"
cat >"$launcher/scripts/phase-ops.sh" <<'PHASE_OPS'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 1 && "$1" == bifrost ]]
[[ "${GDC_BIFROST_EXPECTED_STATE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]
printf '%s\n' "$GDC_BIFROST_EXPECTED_STATE_SHA256" >"${GDC_TEST_PHASE_OPS_SHA:?}"
PHASE_OPS
chmod +x "$launcher/scripts/phase-ops.sh"

if ! GDC_TEST_SSH_LOG="$tmp/apply-dispatch-ssh.log" PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator" GDC_ENV="$tmp/operator/.env" GDC_RUN_ID=bifrost-apply-dispatch \
  "$launcher/gdc.sh" --release v2026.08.06 ops bifrost preview >"$tmp/apply-dispatch-preview.out" 2>"$tmp/apply-dispatch-preview.err"
then
  cat "$tmp/apply-dispatch-preview.out" "$tmp/apply-dispatch-preview.err" >&2
  exit 1
fi
dispatch_receipt="$tmp/operator/runs/bifrost-apply-dispatch/bifrost/preview.json"
dispatch_sha="$(sha256sum "$dispatch_receipt" | awk '{print $1}')"
dispatch_before="$(jq -r '.before_sha256' "$dispatch_receipt")"
GDC_TEST_SSH_LOG="$tmp/apply-dispatch-ssh.log" GDC_TEST_PHASE_OPS_SHA="$tmp/phase-ops.sha" PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator" GDC_ENV="$tmp/operator/.env" GDC_RUN_ID=bifrost-apply-dispatch \
  GDC_BIFROST_APPROVED_PREVIEW_SHA256="$dispatch_sha" \
  "$launcher/gdc.sh" --release v2026.08.06 ops bifrost apply >"$tmp/apply-dispatch.out" 2>"$tmp/apply-dispatch.err"
grep -Fq "$dispatch_before" "$tmp/phase-ops.sha"
if grep -Eq '(docker|rsync|scp|install-ops|bifrost-provision.py --apply)' "$tmp/apply-dispatch-ssh.log"; then
  echo 'Bifrost apply dispatched a remote mutation before phase-ops handoff' >&2
  exit 1
fi
printf 'PASS GDC Bifrost preview launcher creates only the approved receipt\n'
