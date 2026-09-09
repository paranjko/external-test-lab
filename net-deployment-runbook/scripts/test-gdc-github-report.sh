#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/portable.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$ROOT/test/fixtures/mock-gh" "$tmp/bin/gh"
chmod 0755 "$tmp/bin/gh"

run_gdc() {
  GDC_HOME="$tmp/operator" "$ROOT/gdc-bash.sh" "$@"
}

if run_gdc invalid-command >"$tmp/pre.out" 2>"$tmp/pre.err"; then
  echo 'pre-phase failure unexpectedly succeeded' >&2
  exit 1
fi
pointer="$tmp/operator/reporting/failures/latest-failure"
[[ -f "$pointer" && ! -L "$pointer" ]]
failure_id="$(<"$pointer")"
failure="$tmp/operator/reporting/invocations/invocation.$failure_id/failure.env"
[[ -f "$failure" && ! -L "$failure" ]]
grep -qx 'failure_stage=pre-phase' "$failure"
grep -qx 'exit_code=2' "$failure"
# Older records may contain an untrusted reconstruction of the command. It is
# deliberately ignored and must never enter generated report files.
printf 'safe_invocation=/tmp/legacy-runbook/gdc.sh invalid-command\n' >>"$failure"
mkdir -p "$tmp/operator/runs/diagnostic-fixture"
"$ROOT/scripts/diagnostic-envelope.sh" write "$tmp/operator/runs/diagnostic-fixture/diagnostic-envelope.v1.json" \
  join join-node failed interrupted network curl 28 safe join-repeat 'Independent RPC lineage and trust were not established for native P2P state sync.'
printf 'diagnostic_envelope=%s\n' "$tmp/operator/runs/diagnostic-fixture/diagnostic-envelope.v1.json" >>"$failure"
# Current JOIN failures may also retain the private preflight receipt path.
# It is intentionally not copied into the public report.
printf 'preflight_receipt=%s\n' "$tmp/operator/runs/diagnostic-fixture/preflight-receipt.env" >>"$failure"

sort_root="$tmp/sort-operator"
if GDC_HOME="$sort_root" "$ROOT/gdc-bash.sh" invalid-command >"$tmp/sort-pre.out" 2>"$tmp/sort-pre.err"; then
  echo 'failure-order fixture unexpectedly succeeded' >&2
  exit 1
fi
sort_pointer="$sort_root/reporting/failures/latest-failure"
sort_id="$(<"$sort_pointer")"
sort_failure="$sort_root/reporting/invocations/invocation.$sort_id/failure.env"
for entry in \
  'report-old-a 2026-09-02T12:00:00Z' \
  'report-old-b 2026-09-03T12:00:00Z' \
  'report-old-c 2026-09-01T12:00:00Z' \
  'report-old-d 2026-08-31T12:00:00Z' \
  'report-old-e 2026-08-30T12:00:00Z' \
  'report-old-f 2026-08-29T12:00:00Z' \
  'report-old-g 2026-08-28T12:00:00Z' \
  'report-old-h 2026-08-27T12:00:00Z' \
  'report-old-i 2026-08-26T12:00:00Z' \
  'report-old-j 2026-08-25T12:00:00Z' \
  'report-old-k 2026-08-24T12:00:00Z'; do
  read -r old_id old_timestamp <<<"$entry"
  old_dir="$sort_root/reporting/invocations/invocation.$old_id"
  mkdir -p "$old_dir"
  sed -e "s/^invocation_id=.*/invocation_id=$old_id/" \
    -e "s/^recorded_at=.*/recorded_at=$old_timestamp/" \
    "$sort_failure" >"$old_dir/failure.env"
done
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/sort-gh.args" FAKE_GH_BODY="$tmp/sort-gh.md" \
  GDC_REPORT_TEST_INTERACTIVE=true GDC_HOME="$sort_root" \
  "$ROOT/gdc-bash.sh" report github >"$tmp/sort.out" 2>"$tmp/sort.err" <<'EOF'
1
0
EOF
then
  :
fi
grep -Fq 'Publication cancelled' "$tmp/sort.err" || {
  printf '%s\n' 'failure-order fixture did not reach cancellation' >&2
  sed -n '1,120p' "$tmp/sort.out" >&2
  sed -n '1,120p' "$tmp/sort.err" >&2
  exit 1
}
newer_line="$(grep -n '2026-09-03T12:00:00Z' "$tmp/sort.out" | cut -d: -f1)"
older_line="$(grep -n '2026-09-02T12:00:00Z' "$tmp/sort.out" | cut -d: -f1)"
[[ "$newer_line" =~ ^[0-9]+$ && "$older_line" =~ ^[0-9]+$ && "$newer_line" -lt "$older_line" ]]
[[ "$(grep -Ec '^[0-9]+\) 2026-' "$tmp/sort.out")" == 10 ]]
! grep -Eq '^11\) 2026-' "$tmp/sort.out"

if ! PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/gh.args" FAKE_GH_BODY="$tmp/published.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/new.out" 2>"$tmp/new.err" <<'EOF'
1

.
y
EOF
then
  printf '%s\n' 'initial report publication fixture command failed' >&2
  sed -n '1,120p' "$tmp/new.out" >&2
  sed -n '1,120p' "$tmp/new.err" >&2
  exit 1
fi
grep -Fq 'Published and verified: https://github.com/paranjko/external-test-lab/issues/9001' "$tmp/new.out" || {
  printf '%s\n' 'initial report publication fixture failed' >&2
  sed -n '1,120p' "$tmp/new.out" >&2
  sed -n '1,120p' "$tmp/new.err" >&2
  exit 1
}
grep -Fq -- '--body-file ' "$tmp/gh.args"
! grep -Fq 'report contents' "$tmp/gh.args"
grep -Fq 'gdc-report-id:' "$tmp/published.md"
grep -Fq 'gdc-report-sha256:' "$tmp/published.md"
! grep -Fq 'Safe reproduction command' "$tmp/published.md"
! grep -Fq '/tmp/legacy-runbook' "$tmp/published.md"
! grep -Fq 'safe_invocation=' "$tmp/published.md"
grep -Fq '| command_family | join |' "$tmp/published.md"
grep -Fq '| checkpoint | failed |' "$tmp/published.md"
! grep -Fq 'Independent RPC lineage and trust were not established for native P2P state sync.' "$tmp/published.md"
grep -Fq 'Resume decision: `safe`.' "$tmp/published.md"
grep -Fq 'permits repeating the supported `gdc host join` operation' "$tmp/published.md"
! grep -Eq '^\| (docker|gh|docker_compose|nvidia_gpu|filesystem_free_kib) \|' "$tmp/published.md"
grep -Eq '^\| bash \| [0-9][0-9A-Za-z()._-]* \|$' "$tmp/published.md"
! grep -Eiq 'authorization|private key|mnemonic|cookie|token=' "$tmp/published.md"

# An early JOIN preflight can retain a run ID before its optional lifecycle
# manifest exists. The report must render that identity as unavailable.
early_root="$tmp/early-preflight-operator"
if GDC_HOME="$early_root" GDC_RUN_ID=early-preflight-run "$ROOT/gdc-bash.sh" invalid-command >"$tmp/early.out" 2>"$tmp/early.err"; then
  echo 'early-preflight fixture failure unexpectedly succeeded' >&2
  exit 1
fi
early_id="$(<"$early_root/reporting/failures/latest-failure")"
early_failure="$early_root/reporting/invocations/invocation.$early_id/failure.env"
grep -qx 'run_id=early-preflight-run' "$early_failure"
grep -qx 'run_manifest=unavailable' "$early_failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/early.args" FAKE_GH_BODY="$tmp/early.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$early_root" "$ROOT/gdc-bash.sh" report github >"$tmp/early-report.out" 2>"$tmp/early-report.err" <<'EOF'
0
EOF
then
  :
fi
grep -Fq 'Local sanitized report:' "$tmp/early-report.out"
grep -Fq 'Publication cancelled' "$tmp/early-report.err"
report_dir=''
for candidate in "$tmp/operator/reporting/reports"/report.*; do
  [[ -d "$candidate" ]] || continue
  report_dir="$candidate"
  break
done
[[ -n "$report_dir" ]] || { echo 'early report fixture did not create a report directory' >&2; exit 1; }
[[ -d "$report_dir" ]]
[[ "$(gdc_file_mode "$report_dir")" == 700 ]]
[[ "$(gdc_file_mode "$report_dir/report.md")" == 400 ]]
! grep -Fq 'safe_invocation=' "$report_dir/report.txt"
! grep -Fq '/tmp/legacy-runbook' "$report_dir/report.txt"
archive="$report_dir.tar.gz"
[[ "$(gdc_file_mode "$archive")" == 600 ]]
tar -tzf "$archive" | grep -qx 'report.txt'
tar -tzf "$archive" | grep -qx 'report.md'
! tar -tzf "$archive" | grep -Eiq '(^|/)(\.env|.*keyring.*|.*secret.*|.*backup.*|run\.log)$'
# Archive headers are public output too: they must carry neutral numeric
# ownership and read-only member modes, never the local operator identity or
# source-file permissions.
tar --numeric-owner -tvzf "$archive" >"$tmp/archive-listing.txt"
# GNU tar renders numeric ownership as `0/0`; BSD tar renders it as separate
# `0 0` fields.  Both forms prove that no local owner or group leaked.
awk '
  $1 != "-r--r--r--" { exit 1 }
  $2 == "0/0" { next }
  $2 == "0" && $3 == "0" { next }
  { exit 1 }
' "$tmp/archive-listing.txt"

# A first invocation may retain an alias spelling while a later reporter
# canonicalises its existing GDC_HOME. The alias is safe when it resolves
# beneath the same root; rejection would make macOS /var -> /private/var
# paths impossible to report.
canonical_base="$tmp/canonical-report-base"
alias_base="$tmp/alias-report-base"
canonical_root="$canonical_base/report-root"
alias_root="$alias_base/report-root"
mkdir -p "$canonical_root"
ln -s "$canonical_base" "$alias_base"
if GDC_HOME="$alias_root" "$ROOT/gdc-bash.sh" invalid-command >"$tmp/alias-pre.out" 2>"$tmp/alias-pre.err"; then
  echo 'canonical-alias fixture failure unexpectedly succeeded' >&2
  exit 1
fi
alias_id="$(<"$canonical_root/reporting/failures/latest-failure")"
alias_failure="$canonical_root/reporting/invocations/invocation.$alias_id/failure.env"
mkdir -p "$alias_root/runs/diagnostic-fixture"
"$ROOT/scripts/diagnostic-envelope.sh" write "$alias_root/runs/diagnostic-fixture/diagnostic-envelope.v1.json" \
  join join-node failed interrupted network curl 28 safe join-repeat 'Independent RPC lineage and trust were not established for native P2P state sync.'
printf 'diagnostic_envelope=%s\n' "$alias_root/runs/diagnostic-fixture/diagnostic-envelope.v1.json" >>"$alias_failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/alias.args" FAKE_GH_BODY="$tmp/alias.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$alias_root" "$ROOT/gdc-bash.sh" report github >"$tmp/alias-report.out" 2>"$tmp/alias-report.err" <<'EOF'
0
EOF
then
  :
fi
grep -Fq 'Local sanitized report:' "$tmp/alias-report.out"
grep -Fq 'Publication cancelled' "$tmp/alias-report.err"

printf '1\ntest report 09 04 19\r\n.\ny\n' | \
  PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/custom-title.args" FAKE_GH_BODY="$tmp/custom-title.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/custom-title.out" 2>"$tmp/custom-title.err"
grep -Fq 'Published and verified: https://github.com/paranjko/external-test-lab/issues/9001' "$tmp/custom-title.out"
grep -Fq 'test\ report\ 09\ 04\ 19' "$tmp/custom-title.args"

FAKE_GH_ISSUES_JSON='[{"number":9001,"title":"Existing fixture","url":"https://github.com/paranjko/external-test-lab/issues/9001","author":{"login":"fixture-user"}}]' \
PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/comment.args" FAKE_GH_BODY="$tmp/comment.md" FAKE_GH_COMMENT_MODE=true GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/comment.out" 2>"$tmp/comment.err" <<'EOF'
2
.
y
EOF
grep -Fq 'Published and verified: https://github.com/paranjko/external-test-lab/issues/9001#issuecomment-9002' "$tmp/comment.out"
grep -Fq 'issue comment 9001' "$tmp/comment.args"

PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/duplicate.args" FAKE_GH_BODY="$tmp/duplicate.md" FAKE_GH_DUPLICATES=1 GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/duplicate.out" 2>"$tmp/duplicate.err" <<'EOF'
1

.
EOF
grep -Fq 'matching report marker already exists' "$tmp/duplicate.err"
! grep -Eq 'issue (create|comment).*--body-file' "$tmp/duplicate.args" || { echo 'duplicate detection attempted a write' >&2; exit 1; }

if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/missing.args" FAKE_GH_BODY="$tmp/missing.md" FAKE_GH_MISSING=true GDC_REPORT_TEST_INTERACTIVE=true run_gdc report github >"$tmp/missing.out" 2>"$tmp/missing.err" <<'EOF'
EOF
then
  echo 'missing GitHub CLI unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'GitHub CLI is unavailable' "$tmp/missing.err"

if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/auth.args" FAKE_GH_BODY="$tmp/auth.md" FAKE_GH_AUTH=fail GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/auth.out" 2>"$tmp/auth.err" <<'EOF'
EOF
then
  echo 'unauthenticated GitHub CLI unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'not authenticated' "$tmp/auth.err"

PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/cancel.args" FAKE_GH_BODY="$tmp/cancel.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/cancel.out" 2>"$tmp/cancel.err" <<'EOF'
0
EOF
grep -Fq 'Publication cancelled' "$tmp/cancel.err"
! grep -Eq 'issue (create|comment).*--body-file' "$tmp/cancel.args" || { echo 'cancellation attempted a write' >&2; exit 1; }

FAKE_GH_ISSUES_JSON='[{"number":9001,"title":"Existing fixture","url":"https://github.com/paranjko/external-test-lab/issues/9001","author":{"login":"fixture-user","id":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}]' \
PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/projected-issues.args" FAKE_GH_BODY="$tmp/projected-issues.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/projected-issues.out" 2>"$tmp/projected-issues.err" <<'EOF'
0
EOF
grep -Fq 'Publication cancelled' "$tmp/projected-issues.err"
! grep -Fq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$tmp/projected-issues.out" || { echo 'unallowlisted GitHub field reached the terminal' >&2; exit 1; }

hostile_issue_root="$tmp/hostile-issue-operator"
if GDC_HOME="$hostile_issue_root" "$ROOT/gdc-bash.sh" hostile-issue-command >"$tmp/hostile-issue.out" 2>"$tmp/hostile-issue.err"; then
  echo 'hostile issue fixture failure unexpectedly succeeded' >&2
  exit 1
fi
if FAKE_GH_ISSUES_JSON='[{"number":9001,"title":"unsafe\u001b[31m title","url":"https://github.com/paranjko/external-test-lab/issues/9001","author":{"login":"fixture-user"}}]' \
  PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/hostile-issue.args" FAKE_GH_BODY="$tmp/hostile-issue.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$hostile_issue_root" "$ROOT/gdc-bash.sh" report github >"$tmp/hostile-issue-report.out" 2>"$tmp/hostile-issue-report.err" <<'EOF'
EOF
then
  echo 'hostile GitHub issue title unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'GitHub returned an invalid issue list' "$tmp/hostile-issue-report.err"
! grep -Eq 'issue (create|comment).*--body-file' "$tmp/hostile-issue.args" || { echo 'hostile issue title attempted a write' >&2; exit 1; }

if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/context.args" FAKE_GH_BODY="$tmp/context.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/context.out" 2>"$tmp/context.err" <<'EOF'
1

authorization: Bearer fixture-secret-canary
.
EOF
then
  echo 'unsafe optional context unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'optional context is unsafe' "$tmp/context.err"
! grep -Eq 'issue (create|comment).*--body-file' "$tmp/context.args" || { echo 'unsafe context attempted a write' >&2; exit 1; }

PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/attach.args" FAKE_GH_BODY="$tmp/attach.md" FAKE_GH_ATTACH=true GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/attach.out" 2>"$tmp/attach.err" <<'EOF'
1

.
y
EOF
grep -Eq 'issue create.*--attach' "$tmp/attach.args"
grep -Eq 'issue create.*--attach.*report\.[^ ]+\.tar\.gz' "$tmp/attach.args"
! grep -Fq 'run.log' "$tmp/attach.args" || { echo 'attachment attempted to upload a raw log' >&2; exit 1; }

if run_gdc another-invalid-command >"$tmp/second.out" 2>"$tmp/second.err"; then
  echo 'second pre-phase failure unexpectedly succeeded' >&2
  exit 1
fi
PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/select.args" FAKE_GH_BODY="$tmp/select.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/select.out" 2>"$tmp/select.err" <<'EOF'
2
0
EOF
grep -Fq 'Recent failed GDC invocations:' "$tmp/select.out"
grep -Fq 'Publication cancelled' "$tmp/select.err"

unsafe_root="$tmp/unsafe-operator"
if GDC_HOME="$unsafe_root" "$ROOT/gdc-bash.sh" unsafe-command >"$tmp/unsafe.out" 2>"$tmp/unsafe.err"; then
  echo 'unsafe fixture failure unexpectedly succeeded' >&2
  exit 1
fi
rm -f "$unsafe_root/reporting/failures/latest-failure"
ln -s /etc/hosts "$unsafe_root/reporting/failures/latest-failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/symlink.args" FAKE_GH_BODY="$tmp/symlink.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$unsafe_root" "$ROOT/gdc-bash.sh" report github >"$tmp/symlink.out" 2>"$tmp/symlink.err" <<'EOF'
EOF
then
  echo 'symlinked failure pointer unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'no safe recorded failure exists' "$tmp/symlink.err"

canary_root="$tmp/canary-operator"
if GDC_HOME="$canary_root" "$ROOT/gdc-bash.sh" canary-command >"$tmp/canary.out" 2>"$tmp/canary.err"; then
  echo 'canary fixture failure unexpectedly succeeded' >&2
  exit 1
fi
canary_id="$(<"$canary_root/reporting/failures/latest-failure")"
canary_failure="$canary_root/reporting/invocations/invocation.$canary_id/failure.env"
mkdir -p "$canary_root/runs/canary"
printf 'ERROR authorization: Bearer fixture-secret-canary\n' >"$canary_root/runs/canary/run.log"
gdc_sed_inplace "s#^run_log=.*#run_log=$canary_root/runs/canary/run.log#" "$canary_failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/log-canary.args" FAKE_GH_BODY="$tmp/log-canary.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$canary_root" "$ROOT/gdc-bash.sh" report github >"$tmp/log-canary.out" 2>"$tmp/log-canary.err" <<'EOF'
EOF
then
  echo 'secret-bearing diagnostic log unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'diagnostic excerpt is unsafe' "$tmp/log-canary.err"
[[ ! -e "$tmp/log-canary.args" ]] || { echo 'unsafe diagnostic reached GitHub preflight' >&2; exit 1; }

publication_root="$tmp/publication-operator"
if GDC_HOME="$publication_root" "$ROOT/gdc-bash.sh" publication-command >"$tmp/publication.out" 2>"$tmp/publication.err"; then
  echo 'publication fixture failure unexpectedly succeeded' >&2
  exit 1
fi
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/create-fail.args" FAKE_GH_BODY="$tmp/create-fail.md" FAKE_GH_CREATE=fail GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$publication_root" "$ROOT/gdc-bash.sh" report github >"$tmp/create-fail.out" 2>"$tmp/create-fail.err" <<'EOF'
1

.
y
EOF
then
  echo 'failed GitHub write unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'publication state UNKNOWN' "$tmp/create-fail.err"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/ambiguous.args" FAKE_GH_BODY="$tmp/ambiguous.md" FAKE_GH_CREATE=ambiguous GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$publication_root" "$ROOT/gdc-bash.sh" report github >"$tmp/ambiguous.out" 2>"$tmp/ambiguous.err" <<'EOF'
1

.
y
EOF
then
  echo 'ambiguous GitHub write unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'publication state UNKNOWN' "$tmp/ambiguous.err"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/mismatch.args" FAKE_GH_BODY="$tmp/mismatch.md" FAKE_GH_READBACK_MISMATCH=true GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$publication_root" "$ROOT/gdc-bash.sh" report github >"$tmp/mismatch.out" 2>"$tmp/mismatch.err" <<'EOF'
1

.
y
EOF
then
  echo 'readback mismatch unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'readback was incomplete' "$tmp/mismatch.err"

printf 'PASS gdc GitHub report failure, archive, publication, safety, and recovery contracts\n'
