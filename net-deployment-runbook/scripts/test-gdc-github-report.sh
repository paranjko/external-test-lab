#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$ROOT/test/fixtures/mock-gh" "$tmp/bin/gh"
chmod 0755 "$tmp/bin/gh"

run_gdc() {
  GDC_HOME="$tmp/operator" "$ROOT/gdc.sh" "$@"
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
  join join-node failed interrupted network curl 28 safe join-repeat 'network readback timed out'
printf 'diagnostic_envelope=%s\n' "$tmp/operator/runs/diagnostic-fixture/diagnostic-envelope.v1.json" >>"$failure"
# Current JOIN failures may also retain the private preflight receipt path.
# It is intentionally not copied into the public report.
printf 'preflight_receipt=%s\n' "$tmp/operator/runs/diagnostic-fixture/preflight-receipt.env" >>"$failure"

sort_root="$tmp/sort-operator"
if GDC_HOME="$sort_root" "$ROOT/gdc.sh" invalid-command >"$tmp/sort-pre.out" 2>"$tmp/sort-pre.err"; then
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
  "$ROOT/gdc.sh" report github >"$tmp/sort.out" 2>"$tmp/sort.err" <<'EOF'
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

PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/gh.args" FAKE_GH_BODY="$tmp/published.md" GDC_REPORT_TEST_INTERACTIVE=true \
  run_gdc report github >"$tmp/new.out" 2>"$tmp/new.err" <<'EOF'
1

.
y
EOF
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
grep -Fq 'network readback timed out' "$tmp/published.md"
grep -Fq 'Resume decision: `safe`.' "$tmp/published.md"
grep -Fq 'permits repeating the supported `gdc host join` operation' "$tmp/published.md"
! grep -Eq '^\| (docker|gh|docker_compose|nvidia_gpu|filesystem_free_kib) \|' "$tmp/published.md"
grep -Eq '^\| bash \| [0-9][0-9A-Za-z()._-]* \|$' "$tmp/published.md"
! grep -Eiq 'authorization|private key|mnemonic|cookie|token=' "$tmp/published.md"
report_dir="$(find "$tmp/operator/reporting/reports" -maxdepth 1 -mindepth 1 -type d -print -quit)"
[[ -d "$report_dir" ]]
[[ "$(stat -c '%a' "$report_dir")" == 700 ]]
[[ "$(stat -c '%a' "$report_dir/report.md")" == 400 ]]
! grep -Fq 'safe_invocation=' "$report_dir/report.txt"
! grep -Fq '/tmp/legacy-runbook' "$report_dir/report.txt"
archive="$report_dir.tar.gz"
[[ "$(stat -c '%a' "$archive")" == 600 ]]
tar -tzf "$archive" | grep -qx 'report.txt'
tar -tzf "$archive" | grep -qx 'report.md'
! tar -tzf "$archive" | grep -Eiq '(^|/)(\.env|.*keyring.*|.*secret.*|.*backup.*|run\.log)$'

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
if GDC_HOME="$hostile_issue_root" "$ROOT/gdc.sh" hostile-issue-command >"$tmp/hostile-issue.out" 2>"$tmp/hostile-issue.err"; then
  echo 'hostile issue fixture failure unexpectedly succeeded' >&2
  exit 1
fi
if FAKE_GH_ISSUES_JSON='[{"number":9001,"title":"unsafe\u001b[31m title","url":"https://github.com/paranjko/external-test-lab/issues/9001","author":{"login":"fixture-user"}}]' \
  PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/hostile-issue.args" FAKE_GH_BODY="$tmp/hostile-issue.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$hostile_issue_root" "$ROOT/gdc.sh" report github >"$tmp/hostile-issue-report.out" 2>"$tmp/hostile-issue-report.err" <<'EOF'
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
if GDC_HOME="$unsafe_root" "$ROOT/gdc.sh" unsafe-command >"$tmp/unsafe.out" 2>"$tmp/unsafe.err"; then
  echo 'unsafe fixture failure unexpectedly succeeded' >&2
  exit 1
fi
rm -f "$unsafe_root/reporting/failures/latest-failure"
ln -s /etc/hosts "$unsafe_root/reporting/failures/latest-failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/symlink.args" FAKE_GH_BODY="$tmp/symlink.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$unsafe_root" "$ROOT/gdc.sh" report github >"$tmp/symlink.out" 2>"$tmp/symlink.err" <<'EOF'
EOF
then
  echo 'symlinked failure pointer unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'no safe recorded failure exists' "$tmp/symlink.err"

canary_root="$tmp/canary-operator"
if GDC_HOME="$canary_root" "$ROOT/gdc.sh" canary-command >"$tmp/canary.out" 2>"$tmp/canary.err"; then
  echo 'canary fixture failure unexpectedly succeeded' >&2
  exit 1
fi
canary_id="$(<"$canary_root/reporting/failures/latest-failure")"
canary_failure="$canary_root/reporting/invocations/invocation.$canary_id/failure.env"
mkdir -p "$canary_root/runs/canary"
printf 'ERROR authorization: Bearer fixture-secret-canary\n' >"$canary_root/runs/canary/run.log"
sed -i "s#^run_log=.*#run_log=$canary_root/runs/canary/run.log#" "$canary_failure"
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/log-canary.args" FAKE_GH_BODY="$tmp/log-canary.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$canary_root" "$ROOT/gdc.sh" report github >"$tmp/log-canary.out" 2>"$tmp/log-canary.err" <<'EOF'
EOF
then
  echo 'secret-bearing diagnostic log unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'diagnostic excerpt is unsafe' "$tmp/log-canary.err"
[[ ! -e "$tmp/log-canary.args" ]] || { echo 'unsafe diagnostic reached GitHub preflight' >&2; exit 1; }

publication_root="$tmp/publication-operator"
if GDC_HOME="$publication_root" "$ROOT/gdc.sh" publication-command >"$tmp/publication.out" 2>"$tmp/publication.err"; then
  echo 'publication fixture failure unexpectedly succeeded' >&2
  exit 1
fi
if PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/create-fail.args" FAKE_GH_BODY="$tmp/create-fail.md" FAKE_GH_CREATE=fail GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$publication_root" "$ROOT/gdc.sh" report github >"$tmp/create-fail.out" 2>"$tmp/create-fail.err" <<'EOF'
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
  GDC_HOME="$publication_root" "$ROOT/gdc.sh" report github >"$tmp/ambiguous.out" 2>"$tmp/ambiguous.err" <<'EOF'
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
  GDC_HOME="$publication_root" "$ROOT/gdc.sh" report github >"$tmp/mismatch.out" 2>"$tmp/mismatch.err" <<'EOF'
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
