#!/usr/bin/env bash
# Exercise the public-report contract with real launcher failure records. The
# assertions parse report table rows as data; they do not inspect source text.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$ROOT/test/fixtures/mock-gh" "$tmp/bin/gh"
chmod 0755 "$tmp/bin/gh"

prepare_failure() {
  local home="$1" pointer id failure
  if GDC_HOME="$home" "$ROOT/gdc.sh" invalid-command >"$tmp/pre.out" 2>"$tmp/pre.err"; then
    echo 'fixture invalid command unexpectedly succeeded' >&2
    exit 1
  fi
  pointer="$home/reporting/failures/latest-failure"
  id="$(<"$pointer")"
  failure="$home/reporting/invocations/invocation.$id/failure.env"
  [[ -f "$failure" && ! -L "$failure" ]]
  printf '%s\n' "$failure"
}

assert_rows() {
  local report="$1"
  awk '
    $0 == "## Signer diagnostic" { section=1; seen=1; next }
    section && /^## / { section=0 }
    section && /^\| / && $0 !~ /^\| Field \|/ && $0 !~ /^\| --- / {
      if (split($0, cells, /[|]/) == 4) {
        key=cells[2]; value=cells[3]
        gsub(/^ +| +$/, "", key); gsub(/^ +| +$/, "", value)
        values[key]=value
      }
    }
    END {
      if (!seen) exit 1
      expected["last_completed_checkpoint"]="deployment_installed"
      expected["failed_checkpoint"]="canary_running"
      expected["error_class"]="transport"
      expected["transport_stage"]="canary_image_pull"
      expected["transport_result"]="connection_reset"
      expected["mutation_state"]="staging_only"
      expected["signer_readback"]="disabled"
      expected["attempt_count"]="3"
      expected["recovery_decision"]="safe"
      expected["recovery_token"]="join-repeat"
      for (key in expected) if (values[key] != expected[key]) exit 1
    }
  ' "$report"
}

home="$tmp/operator"
failure="$(prepare_failure "$home")"
receipt="$(dirname "$failure")/signer-diagnostic.v1.json"
"$ROOT/scripts/join-signer-diagnostic.sh" write "$receipt" run-208-fixture validator-c join-validator-c \
  deployment_installed canary_running transport 255 3 staging_only disabled canary_image_pull connection_reset \
  safe join-repeat 'The signerless synchronization canary stopped at transport stage canary_image_pull before any signer change.'
printf 'signer_diagnostic=%s\n' "$receipt" >>"$failure"

PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/gh.args" FAKE_GH_BODY="$tmp/report.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$home" "$ROOT/gdc.sh" report github >"$tmp/report.out" 2>"$tmp/report.err" <<'EOF'
1

.
y
EOF
assert_rows "$tmp/report.md"
awk 'index($0, "run-208-fixture") { unsafe=1 } END { exit unsafe }' "$tmp/report.md"

# A post-activation uncertainty uses the same bounded table but must retain
# its manual-recovery direction. This is a reporter behavior check, not a
# search for renderer source text.
assert_manual_recovery_rows() {
  local report="$1"
  awk '
    $0 == "## Signer diagnostic" { section=1; seen=1; next }
    section && /^## / { section=0 }
    section && /^\| / && $0 !~ /^\| Field \|/ && $0 !~ /^\| --- / {
      if (split($0, cells, /[|]/) == 4) {
        key=cells[2]; value=cells[3]
        gsub(/^ +| +$/, "", key); gsub(/^ +| +$/, "", value)
        values[key]=value
      }
    }
    END {
      if (!seen) exit 1
      expected["last_completed_checkpoint"]="signer_activating"
      expected["failed_checkpoint"]="signer_enabled"
      expected["error_class"]="readback"
      expected["transport_stage"]="signer_active_readback"
      expected["transport_result"]="timeout"
      expected["mutation_state"]="signer_may_be_on"
      expected["signer_readback"]="unavailable"
      expected["attempt_count"]="1"
      expected["recovery_decision"]="manual_action_required"
      expected["recovery_token"]="none"
      for (key in expected) if (values[key] != expected[key]) exit 1
    }
  ' "$report"
}

manual_home="$tmp/manual-operator"
manual_failure="$(prepare_failure "$manual_home")"
manual_receipt="$(dirname "$manual_failure")/signer-diagnostic.v1.json"
"$ROOT/scripts/join-signer-diagnostic.sh" write "$manual_receipt" manual-readback-run validator-c join-validator-c \
  signer_activating signer_enabled readback 1 1 signer_may_be_on unavailable signer_active_readback timeout \
  manual_action_required none 'The signer state could not be read after activation; do not retry automatically.'
printf 'signer_diagnostic=%s\n' "$manual_receipt" >>"$manual_failure"
PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/manual-gh.args" FAKE_GH_BODY="$tmp/manual-report.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$manual_home" "$ROOT/gdc.sh" report github >"$tmp/manual.out" 2>"$tmp/manual.err" <<'EOF'
1

.
y
EOF
assert_manual_recovery_rows "$tmp/manual-report.md"
awk '
  /manual-readback-run|signer state could not be read|\/tmp\// { unsafe=1 }
  /automatic retry is safe|gdc host join .*--/ { retry=1 }
  END { exit (unsafe || retry) }
' "$tmp/manual-report.md"

# A failure that has no phase-owned signer receipt keeps the same report shape
# but makes the causal boundary explicit rather than inventing an explanation.
absent_home="$tmp/absent-operator"
prepare_failure "$absent_home" >/dev/null
PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/absent-gh.args" FAKE_GH_BODY="$tmp/absent-report.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$absent_home" "$ROOT/gdc.sh" report github >"$tmp/absent.out" 2>"$tmp/absent.err" <<'EOF'
1

.
y
EOF
awk '
  $0 == "## Signer diagnostic" { section=1; next }
  section && /^## / { section=0 }
  section && /insufficient to classify a signer stop causally/ { explanation=1 }
  section && /^\| last_completed_checkpoint \| unavailable \|$/ { checkpoint=1 }
  section && /^\| recovery_token \| unavailable \|$/ { token=1 }
  END { exit !(explanation && checkpoint && token) }
' "$tmp/absent-report.md"

# A malformed receipt is a publication stop, not a silent fallback to an
# unavailable table.
bad_home="$tmp/bad-operator"
bad_failure="$(prepare_failure "$bad_home")"
bad_receipt="$(dirname "$bad_failure")/signer-diagnostic.v1.json"
"$ROOT/scripts/join-signer-diagnostic.sh" write "$bad_receipt" fixture-run validator-c join-validator-c \
  deployment_installed canary_running transport 255 1 staging_only disabled canary_image_pull connection_reset \
  safe join-repeat 'The signerless synchronization canary stopped at transport stage canary_image_pull before any signer change.'
jq '.error_class = "invented"' "$bad_receipt" >"$bad_receipt.tmp"
chmod 600 "$bad_receipt.tmp"
mv "$bad_receipt.tmp" "$bad_receipt"
printf 'signer_diagnostic=%s\n' "$bad_receipt" >>"$bad_failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/bad-gh.args" FAKE_GH_BODY="$tmp/bad-report.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$bad_home" "$ROOT/gdc.sh" report github >"$tmp/bad.out" 2>"$tmp/bad.err" <<'EOF'
1
EOF
then
  echo 'an invalid signer diagnostic unexpectedly reached publication' >&2
  exit 1
fi
awk 'index($0, "signer diagnostic is invalid") { found=1 } END { exit !found }' "$tmp/bad.err"

printf 'test-gdc-github-signer-diagnostic: PASS\n'
