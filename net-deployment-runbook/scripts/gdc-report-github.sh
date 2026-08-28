#!/usr/bin/env bash
# Create a local, public-safe support report from one recorded GDC failure.
set -Eeuo pipefail
umask 077

readonly REPORT_REPOSITORY='paranjko/external-test-lab'
readonly REPORT_SCHEMA_VERSION=1
readonly GH_INSTALL_URL='https://cli.github.com/'
readonly MAX_BODY_BYTES=48000

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GDC_DATA_ROOT="${GDC_DATA_ROOT:?gdc report github must be launched by gdc.sh}"
REPORTING_ROOT="$GDC_DATA_ROOT/reporting"
FAILURES_ROOT="$REPORTING_ROOT/failures"

die() { printf 'ERROR gdc report github: %s\n' "$*" >&2; exit 1; }
notice() { printf '%s\n' "$*" >&2; }

require_regular_beneath() {
  local root="$1" candidate="$2" resolved_root resolved
  [[ -d "$root" && ! -L "$root" ]] || return 1
  resolved_root="$(realpath -e -- "$root")" || return 1
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  resolved="$(realpath -e -- "$candidate")" || return 1
  [[ "$resolved" == "$resolved_root/"* ]] || return 1
  while [[ "$candidate" != "$root" ]]; do
    [[ ! -L "$candidate" ]] || return 1
    candidate="$(dirname "$candidate")"
  done
}

read_failure_record() {
  local record="$1" key value seen_keys=' '
  require_regular_beneath "$REPORTING_ROOT" "$record" || die 'selected failure record is unsafe; inspect the local reporting directory'
  FAILURE_SCHEMA_VERSION='' FAILURE_INVOCATION_ID='' FAILURE_EXIT_CODE='' FAILURE_STAGE='' FAILURE_PHASE='' FAILURE_RUN_ID='' FAILURE_RECORDED_AT='' FAILURE_SAFE_INVOCATION='' FAILURE_RUN_MANIFEST='' FAILURE_RUN_LOG=''
  while IFS='=' read -r key value; do
    [[ "$seen_keys" != *" $key "* ]] || die 'failure record has a duplicate field'
    seen_keys+="$key "
    case "$key" in
      schema_version) [[ "$value" == 1 ]] || die 'unsupported failure record schema'; FAILURE_SCHEMA_VERSION="$value" ;;
      invocation_id) [[ "$value" =~ ^[A-Za-z0-9._-]{6,128}$ ]] || die 'unsafe invocation identifier'; FAILURE_INVOCATION_ID="$value" ;;
      exit_code) [[ "$value" =~ ^[1-9][0-9]*$ ]] || die 'unsafe exit code'; FAILURE_EXIT_CODE="$value" ;;
      failure_stage) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die 'unsafe failure stage'; FAILURE_STAGE="$value" ;;
      active_phase) [[ "$value" == unavailable || "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die 'unsafe active phase'; FAILURE_PHASE="$value" ;;
      run_id) [[ "$value" == unavailable || "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die 'unsafe run identifier'; FAILURE_RUN_ID="$value" ;;
      safe_invocation) [[ "${#value}" -le 1024 && "$value" == 'gdc'* ]] && is_public_single_line "$value" || die 'unsafe invocation text'; FAILURE_SAFE_INVOCATION="$value" ;;
      run_manifest) FAILURE_RUN_MANIFEST="$value" ;;
      run_log) FAILURE_RUN_LOG="$value" ;;
      envelope) : ;; # Private paths are deliberately not collected.
      recorded_at) [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]] || die 'unsafe failure timestamp'; FAILURE_RECORDED_AT="$value" ;;
      *) die 'failure record has an unsupported field' ;;
    esac
  done <"$record"
  [[ -n "$FAILURE_SCHEMA_VERSION" && -n "$FAILURE_INVOCATION_ID" && -n "$FAILURE_EXIT_CODE" && -n "$FAILURE_STAGE" && -n "$FAILURE_RECORDED_AT" && -n "$FAILURE_SAFE_INVOCATION" ]] || die 'failure record is incomplete'
}

collect_diagnostic_excerpt() {
  local log="$FAILURE_RUN_LOG" excerpt
  DIAGNOSTIC_EXCERPT='No public-safe run-log excerpt was available. The report records the typed launcher failure envelope instead.'
  [[ -n "$log" && "$log" != unavailable ]] || return 0
  require_regular_beneath "$GDC_DATA_ROOT" "$log" || die 'run log is unsafe; retained report was not published'
  [[ "$(wc -c <"$log")" -le 16777216 ]] || die 'run log exceeds the 16 MiB collection bound; select a narrower failure record'
  excerpt="$(tail -c 65536 "$log" | awk '
    /^BEGIN phase=[A-Za-z0-9._-]+ timestamp=[0-9TZ:-]+ run_id=[A-Za-z0-9._-]+$/ { print; next }
    /^END phase=[A-Za-z0-9._-]+ status=[0-9]+ timestamp=[0-9TZ:-]+$/ { print; next }
    /^ERROR [^[:cntrl:]]+$/ { print; next }
    /^error: [^[:cntrl:]]+$/ { print; next }
  ' | head -n 40 | strip_controls | sed -E 's#/(home|root|tmp)/[^[:space:]]+#<local-path>#g')"
  [[ -n "$excerpt" ]] || return 0
  printf '%s\n' "$excerpt" >"$REPORT_DIR/.diagnostic-excerpt"
  scan_public_text "$REPORT_DIR/.diagnostic-excerpt" || die 'sanitized diagnostic excerpt is unsafe for public disclosure; retained report was not published'
  DIAGNOSTIC_EXCERPT="$excerpt"
  rm -f "$REPORT_DIR/.diagnostic-excerpt"
}

collect_manifest_identity() {
  local key value manifest="$FAILURE_RUN_MANIFEST"
  MANIFEST_RELEASE_PROFILE='unavailable' MANIFEST_RELEASE_SHA256='unavailable' MANIFEST_PROFILE_SHA256='unavailable' MANIFEST_GENESIS_SHA256='unavailable' MANIFEST_CHAIN_ID='unavailable'
  [[ -n "$manifest" && "$manifest" != unavailable ]] || return 0
  require_regular_beneath "$GDC_DATA_ROOT" "$manifest" || die 'run manifest is unsafe; retained report was not published'
  while IFS='=' read -r key value; do
    case "$key" in
      release_profile) [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] && MANIFEST_RELEASE_PROFILE="$value" ;;
      release_profile_sha256) [[ "$value" =~ ^[0-9a-f]{64}$ ]] && MANIFEST_RELEASE_SHA256="$value" ;;
      profile_hash) [[ "$value" =~ ^[0-9a-f]{64}$ ]] && MANIFEST_PROFILE_SHA256="$value" ;;
      genesis_sha256) [[ "$value" =~ ^[0-9a-f]{64}$ ]] && MANIFEST_GENESIS_SHA256="$value" ;;
      chain_id) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] && MANIFEST_CHAIN_ID="$value" ;;
    esac
  done <"$manifest"
}

select_failure() {
  local pointer selected record choice index
  local -a records=()
  pointer="$FAILURES_ROOT/latest-failure"
  require_regular_beneath "$FAILURES_ROOT" "$pointer" || die 'no safe recorded failure exists; run a failed GDC command first'
  selected="$(<"$pointer")"
  [[ "$selected" =~ ^[A-Za-z0-9._-]{6,128}$ ]] || die 'latest-failure pointer is malformed'
  record="$REPORTING_ROOT/invocations/invocation.$selected/failure.env"
  # The pointer contains an identifier, never a path supplied by an operator.
  require_regular_beneath "$REPORTING_ROOT" "$record" || die 'latest failure record is unsafe; inspect the local reporting directory'
  records+=("$record")
  while IFS= read -r record; do
    [[ "$record" == "${records[0]}" ]] && continue
    require_regular_beneath "$REPORTING_ROOT" "$record" || die 'recent failure record is unsafe; inspect the local reporting directory'
    records+=("$record")
  done < <(find -P "$REPORTING_ROOT/invocations" -mindepth 2 -maxdepth 2 -type f -name failure.env -print 2>/dev/null | LC_ALL=C sort -r)
  if (( ${#records[@]} > 1 )) && interactive; then
    printf 'Recent failed GDC invocations:\n'
    index=1
    for record in "${records[@]}"; do
      read_failure_record "$record"
      printf '%s) %s – phase=%s exit=%s%s\n' "$index" "$FAILURE_RECORDED_AT" "$FAILURE_STAGE" "$FAILURE_EXIT_CODE" "$([[ "$index" == 1 ]] && printf ' (latest)')"
      index=$((index + 1))
    done
    printf 'Select failure [1]: '
    read -r choice || choice=1
    [[ -n "$choice" ]] || choice=1
    [[ "$choice" =~ ^[1-9][0-9]*$ && "$choice" -le "${#records[@]}" ]] || die 'invalid failure selection; no GitHub write was attempted'
    record="${records[$((choice - 1))]}"
  else
    record="${records[0]}"
  fi
  read_failure_record "$record"
}

strip_controls() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | sed -E 's/[[:space:]]+$//'
}

is_public_single_line() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  printf '%s' "$value" | LC_ALL=C grep -Eq '^[ -~]*$'
}

scan_public_text() {
  local file="$1"
  LC_ALL=C grep -Ein \
    -e '-----BEGIN( [A-Z0-9 ]+)? PRIVATE KEY-----' \
    -e '(authorization|cookie|x-api-key)[[:space:]]*[:=]' \
    -e '(token|secret|password|mnemonic|private_key|gateway_key)[[:space:]]*[:=]' \
    -e 'https?://[^[:space:]@/]+:[^[:space:]@/]+@' \
    -e '([[:alnum:]]+ ){11,23}[[:alnum:]]+' \
    -e '[A-Za-z0-9+/_=-]{48,}' \
    <(sed -E \
      -e '/^(runbook_revision|launcher_sha256|body_sha256|release_profile_sha256|profile_sha256|genesis_sha256)=[0-9a-f]{40,64}$/d' \
      -e '/^<!-- gdc-report-sha256:[0-9a-f]{64} -->$/d' \
      -e '/(runbook_revision|launcher_sha256|body_sha256|release_profile_sha256|profile_sha256|genesis_sha256|gdc-report-sha256)/ s/[0-9a-f]{40,64}/SHA256/g' \
      "$file") >/dev/null && return 1
  return 0
}

scan_inventory() {
  local file="$1"
  awk '$0 !~ /^[0-9a-f]{64}  (report\.txt|report\.md)$/ { exit 1 }' "$file"
}

escape_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

safe_probe() {
  local label="$1"; shift
  local value
  value="$(timeout 3 "$@" 2>/dev/null | head -c 160 | tr '\n' ' ' | strip_controls || true)"
  [[ -n "$value" ]] || value='unavailable'
  value="$(printf '%s' "$value" | LC_ALL=C tr -c 'A-Za-z0-9 .,_+:/()=-' '_')"
  printf '%s=%s\n' "$label" "$value"
}

write_report() {
  local report_dir metadata body inventory
  report_dir="$1"
  metadata="$report_dir/report.txt"
  body="$report_dir/report.md"
  inventory="$report_dir/SHA256SUMS"
  local report_id created_at body_hash
  report_id="gdc-${FAILURE_RECORDED_AT//[-:TZ]/}-${FAILURE_INVOCATION_ID}"
  created_at="$(date -u +%FT%TZ)"
  collect_manifest_identity
  collect_diagnostic_excerpt
  {
    printf 'schema_version=%s\n' "$REPORT_SCHEMA_VERSION"
    printf 'report_id=%s\n' "$report_id"
    printf 'created_at=%s\n' "$created_at"
    printf 'failure_recorded_at=%s\n' "$FAILURE_RECORDED_AT"
    printf 'failure_stage=%s\n' "$FAILURE_STAGE"
    printf 'active_phase=%s\n' "${FAILURE_PHASE:-unavailable}"
    printf 'exit_code=%s\n' "$FAILURE_EXIT_CODE"
    printf 'run_id=%s\n' "${FAILURE_RUN_ID:-unavailable}"
    printf 'safe_invocation=%s\n' "$FAILURE_SAFE_INVOCATION"
    printf 'release_profile=%s\n' "$MANIFEST_RELEASE_PROFILE"
    printf 'release_profile_sha256=%s\n' "$MANIFEST_RELEASE_SHA256"
    printf 'profile_sha256=%s\n' "$MANIFEST_PROFILE_SHA256"
    printf 'chain_id=%s\n' "$MANIFEST_CHAIN_ID"
    printf 'genesis_sha256=%s\n' "$MANIFEST_GENESIS_SHA256"
    printf 'runbook_revision=%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unavailable)"
    printf 'launcher_sha256=%s\n' "$(sha256sum "$ROOT/gdc.sh" | awk '{print $1}')"
    safe_probe 'os' uname -s
    safe_probe 'kernel' uname -r
    safe_probe 'architecture' uname -m
    safe_probe 'bash' bash --version
    safe_probe 'docker' docker --version
    safe_probe 'gh' gh --version
    safe_probe 'docker_compose' docker compose version
    safe_probe 'nvidia_gpu' nvidia-smi --query-gpu=name --format=csv,noheader
    printf 'filesystem_free_kib=%s\n' "$(df -Pk "$GDC_DATA_ROOT" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4; exit }')"
    safe_probe 'utc_clock' date -u +%FT%TZ
  } >"$metadata"
  scan_public_text "$metadata" || die "unsafe generated metadata; retained $report_dir"
  {
    printf '# GDC failure report\n\n'
    printf 'This report records observations from a failed command. It does not classify the incident as a Gonka product defect.\n\n'
    printf '## Summary\n\n'
    printf '| Field | Value |\n| --- | --- |\n'
    awk -F= 'BEGIN { OFS=" | " } $1 ~ /^(report_id|created_at|failure_recorded_at|failure_stage|active_phase|exit_code|run_id|release_profile|release_profile_sha256|profile_sha256|chain_id|genesis_sha256|runbook_revision|launcher_sha256)$/ { print "| " $1, $2 " |" }' "$metadata"
    printf '\n## Safe reproduction command\n\n<code>'
    awk -F= '$1 == "safe_invocation" { sub(/^[^=]*=/, ""); print; exit }' "$metadata" | escape_html
    printf '</code>\n'
    printf '\n## Environment\n\n| Field | Value |\n| --- | --- |\n'
    awk -F= 'BEGIN { OFS=" | " } $1 ~ /^(os|kernel|architecture|bash|docker|docker_compose|gh|nvidia_gpu|filesystem_free_kib|utc_clock)$/ { gsub(/\|/, "\\|", $2); print "| " $1, $2 " |" }' "$metadata"
    printf '\n## Sanitized diagnostic excerpt\n\n<pre>\n'
    printf '%s\n' "$DIAGNOSTIC_EXCERPT" | escape_html
    printf '</pre>\n'
    printf '\n## Collection limits\n\n'
    printf 'The reporter uses typed local metadata only. It excludes raw logs, role files, environment files, keyrings, backups, credentials, request content, and arbitrary operator files.\n\n'
    printf '<!-- gdc-report-id:%s -->\n' "$report_id"
  } >"$body"
  scan_public_text "$body" || die "unsafe generated report body; retained $report_dir"
  REPORT_ID="$report_id"
  finalize_report "$report_dir"
}

finalize_report() {
  local report_dir="$1" metadata="$1/report.txt" body="$1/report.md" inventory="$1/SHA256SUMS" body_hash
  sed -i '/^<!-- gdc-report-sha256:/d' "$body"
  sed -i '/^body_sha256=/d' "$metadata"
  scan_public_text "$metadata" || die "unsafe generated metadata; retained $report_dir"
  scan_public_text "$body" || die "unsafe generated report body; retained $report_dir"
  [[ "$(wc -c <"$body")" -le "$MAX_BODY_BYTES" ]] || die "mandatory report body exceeds $MAX_BODY_BYTES bytes; retained $report_dir"
  body_hash="$(sha256sum "$body" | awk '{print $1}')"
  printf '<!-- gdc-report-sha256:%s -->\n' "$body_hash" >>"$body"
  printf 'body_sha256=%s\n' "$body_hash" >>"$metadata"
  (cd "$report_dir" && sha256sum report.txt report.md >"$inventory")
  scan_inventory "$inventory" || die "unsafe generated inventory; retained $report_dir"
  REPORT_HASH="$body_hash"
}

archive_report() {
  local report_dir archive extracted
  report_dir="$1"
  archive="$report_dir.tar.gz"
  tar --no-recursion --numeric-owner --owner=0 --group=0 --mode='u=rw,go=' -C "$report_dir" -czf "$archive" report.txt report.md SHA256SUMS
  chmod 0600 "$archive"
  if tar -tzf "$archive" | grep -E '(^|/)(\.env|.*keyring.*|.*secret.*|.*backup.*|run\.log)$' >/dev/null; then
    die "unsafe archive member; retained $report_dir"
  fi
  [[ "$(tar -tzf "$archive" | LC_ALL=C sort)" == $'SHA256SUMS\nreport.md\nreport.txt' ]] || die "archive member inventory is unsafe; retained $report_dir"
  extracted="$(mktemp "$report_dir/.archive-member.XXXXXX")"
  tar -xOzf "$archive" report.txt >"$extracted"
  scan_public_text "$extracted" || { rm -f "$extracted"; die "unsafe archived metadata; retained $report_dir"; }
  tar -xOzf "$archive" report.md >"$extracted"
  scan_public_text "$extracted" || { rm -f "$extracted"; die "unsafe archived report body; retained $report_dir"; }
  tar -xOzf "$archive" SHA256SUMS >"$extracted"
  scan_inventory "$extracted" || { rm -f "$extracted"; die "unsafe archived inventory; retained $report_dir"; }
  rm -f "$extracted"
  ARCHIVE_PATH="$archive"
}

interactive() { [[ -t 0 && -t 1 || "${GDC_REPORT_TEST_INTERACTIVE:-false}" == true ]]; }

gh_preflight() {
  command -v gh >/dev/null 2>&1 && gh --version >/dev/null 2>&1 || { notice "GitHub CLI is unavailable. Install it from $GH_INSTALL_URL; local report retained at $REPORT_DIR"; return 1; }
  gh auth status >/dev/null 2>&1 || { notice "GitHub CLI is not authenticated. Run gh auth login; local report retained at $REPORT_DIR"; return 1; }
  GH_LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
  [[ "$GH_LOGIN" =~ ^[A-Za-z0-9-]{1,39}$ ]] || { notice "GitHub login could not be resolved; local report retained at $REPORT_DIR"; return 1; }
  [[ "$(gh api "repos/$REPORT_REPOSITORY" --jq '.permissions.push' 2>/dev/null || true)" == true ]] || { notice "GitHub issue write permission is unavailable; local report retained at $REPORT_DIR"; return 1; }
  gh issue list --repo "$REPORT_REPOSITORY" --author "$GH_LOGIN" --state open --limit 100 --json number,title,url,author >"$REPORT_DIR/.open-issues.raw.json" || { notice "GitHub issue access is unavailable; local report retained at $REPORT_DIR"; return 1; }
  jq -e --arg login "$GH_LOGIN" '
    type == "array" and all(.[];
      (.number | type == "number") and
      (.url | type == "string" and test("^https://github\\.com/paranjko/external-test-lab/issues/[1-9][0-9]*$")) and
      (.author.login == $login) and
      (.title | type == "string" and length >= 1 and length <= 160 and all(explode[]; . >= 32 and . != 127))
    )
  ' "$REPORT_DIR/.open-issues.raw.json" >/dev/null || { notice "GitHub returned an invalid issue list; local report retained at $REPORT_DIR"; return 1; }
  jq -c '[.[] | {number, title, url, author: {login: .author.login}}]' "$REPORT_DIR/.open-issues.raw.json" >"$REPORT_DIR/open-issues.json"
  rm -f "$REPORT_DIR/.open-issues.raw.json"
  ATTACHMENT_STATE='not supported by this GitHub CLI; inline Markdown is the complete report'
  attachment_args=()
  if gh issue create --help 2>/dev/null | grep -Fq -- '--attach' && gh issue comment --help 2>/dev/null | grep -Fq -- '--attach' && command -v file >/dev/null 2>&1 && [[ "$(file -b --mime-type "$ARCHIVE_PATH")" == application/gzip ]]; then
    ATTACHMENT_STATE='supported and preflighted; the sanitized archive will also be attached'
    attachment_args=(--attach "$ARCHIVE_PATH")
  fi
}

append_optional_context() {
  local context_file="$REPORT_DIR/operator-context.txt" line bytes
  : >"$context_file"
  chmod 0600 "$context_file"
  printf 'Optional public context. Enter text lines; a single period finishes. Leave blank then period to omit.\n'
  while IFS= read -r line; do
    [[ "$line" == . ]] && break
    printf '%s\n' "$line" >>"$context_file"
  done
  bytes="$(wc -c <"$context_file")"
  [[ "$bytes" -le 4000 ]] || die "optional context exceeds 4000 bytes; retained $REPORT_DIR"
  [[ "$bytes" -eq 0 ]] && return 0
  LC_ALL=C grep -q '[[:cntrl:]]' "$context_file" && die "optional context has control characters; retained $REPORT_DIR"
  scan_public_text "$context_file" || die "optional context is unsafe for public disclosure; retained $REPORT_DIR"
  {
    printf '\n## Operator context\n\n<pre>\n'
    strip_controls <"$context_file" | escape_html
    printf '</pre>\n'
  } >>"$REPORT_DIR/report.md"
  finalize_report "$REPORT_DIR"
  archive_report "$REPORT_DIR"
}

freeze_publication_body() {
  local body="$REPORT_DIR/report.md"
  scan_public_text "$body" || die "final report body is unsafe; retained $REPORT_DIR"
  grep -Fqx "<!-- gdc-report-sha256:$REPORT_HASH -->" "$body" || die "final report hash marker is inconsistent; retained $REPORT_DIR"
  chmod 0400 "$body"
}

read_issue_title() {
  local candidate title_file="$REPORT_DIR/issue-title.txt"
  printf 'New issue title [%s]: ' "$title"
  read -r candidate || candidate=''
  [[ -n "$candidate" ]] || return 0
  [[ "${#candidate}" -le 160 ]] && is_public_single_line "$candidate" || die "issue title is unsafe; retained $REPORT_DIR"
  printf '%s\n' "$candidate" >"$title_file"
  scan_public_text "$title_file" || die "issue title is unsafe for public disclosure; retained $REPORT_DIR"
  rm -f "$title_file"
  title="$candidate"
}

find_duplicate() {
  local duplicate
  duplicate="$(gh api "search/issues?q=repo%3A$REPORT_REPOSITORY%20author%3A$GH_LOGIN%20%22gdc-report-id%3A$REPORT_ID%22" --jq '.total_count' 2>/dev/null || true)"
  [[ "$duplicate" =~ ^[0-9]+$ ]] || { notice "Existing report lookup was ambiguous; publication state UNKNOWN and local report retained at $REPORT_DIR"; return 2; }
  if [[ "$duplicate" != 0 ]]; then
    notice "A matching report marker already exists. No duplicate will be published; local report retained at $REPORT_DIR"
    return 1
  fi
  return 0
}

verify_issue() {
  local url="$1" expected_comment="${2:-false}" readback comment_url
  readback="$(gh issue view "$url" --repo "$REPORT_REPOSITORY" --json url,author,body,comments 2>/dev/null || true)"
  printf '%s\n' "$readback" >"$REPORT_DIR/readback.json"
  jq -e --arg login "$GH_LOGIN" --arg report_id "$REPORT_ID" --arg report_hash "$REPORT_HASH" --arg url "$url" \
    '.url == $url and .author.login == $login and ((.body // "") | contains("gdc-report-id:" + $report_id) and contains("gdc-report-sha256:" + $report_hash))' \
    "$REPORT_DIR/readback.json" >/dev/null && [[ "$expected_comment" == false ]] || {
      if [[ "$expected_comment" == true ]]; then
        comment_url="$(jq -r --arg login "$GH_LOGIN" --arg report_id "$REPORT_ID" --arg report_hash "$REPORT_HASH" '.comments[] | select(.author.login == $login and (.body | contains("gdc-report-id:" + $report_id)) and (.body | contains("gdc-report-sha256:" + $report_hash))) | .url' "$REPORT_DIR/readback.json" | head -n1)"
        [[ "$comment_url" =~ ^https://github\.com/paranjko/external-test-lab/issues/[1-9][0-9]*#issuecomment-[1-9][0-9]*$ ]] || return 1
        PUBLICATION_URL="$comment_url"
        return 0
      fi
      return 1
    }
  PUBLICATION_URL="$url"
}

publish() {
  local choice index issue_number title result url duplicate_rc
  interactive || die "an interactive terminal is required; local report retained at $REPORT_DIR"
  gh_preflight || return 1
  printf 'Destination: public repository %s\nLocal archive retained: %s\n' "$REPORT_REPOSITORY" "$ARCHIVE_PATH"
  printf 'Attachment: %s\n\n' "$ATTACHMENT_STATE"
  printf '1) Create a new issue\n'
  index=2
  while IFS=$'\t' read -r issue_number title; do
    printf '%s) Add a comment to #%s: %s\n' "$index" "$issue_number" "$title"
    index=$((index + 1))
  done < <(jq -r '.[] | [.number, .title] | @tsv' "$REPORT_DIR/open-issues.json")
  printf '0) Cancel\nChoose destination [0]: '
  read -r choice || choice=2
  [[ -n "$choice" ]] || choice=0
  case "$choice" in
    1)
      title="GDC failure report: $FAILURE_STAGE (exit $FAILURE_EXIT_CODE)"
      read_issue_title
      issue_number=''
      ;;
    0) notice "Publication cancelled. Local report retained at $REPORT_DIR"; return 0 ;;
    *)
      [[ "$choice" =~ ^[2-9][0-9]*$ ]] || { notice "Publication cancelled. Local report retained at $REPORT_DIR"; return 0; }
      issue_number="$(jq -r ".[$((choice - 2))].number // empty" "$REPORT_DIR/open-issues.json")"
      [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || { notice "Publication cancelled. Local report retained at $REPORT_DIR"; return 0; }
      ;;
  esac
  append_optional_context
  freeze_publication_body
  if find_duplicate; then
    :
  else
    duplicate_rc=$?
    [[ "$duplicate_rc" == 1 ]] && return 0
    return "$duplicate_rc"
  fi
  printf '\nPublic warning: %s is public. The exact body below will be published.\n\n' "$REPORT_REPOSITORY"
  sed -n '1,300p' "$REPORT_DIR/report.md"
  printf '\nPublish this report? [y/N]: '
  read -r choice || choice=n
  [[ "$choice" == y || "$choice" == Y ]] || { notice "Publication cancelled. Local report retained at $REPORT_DIR"; return 0; }
  if [[ -z "$issue_number" ]]; then
    result="$(gh issue create --repo "$REPORT_REPOSITORY" --title "$title" --body-file "$REPORT_DIR/report.md" "${attachment_args[@]}" 2>&1)" || { notice "GitHub issue creation failed; publication state UNKNOWN and local report retained at $REPORT_DIR"; return 1; }
    url="$(printf '%s\n' "$result" | tail -n1)"
    [[ "$url" =~ ^https://github\.com/paranjko/external-test-lab/issues/[1-9][0-9]*$ ]] || { notice "GitHub response was ambiguous; publication state UNKNOWN and local report retained at $REPORT_DIR"; return 1; }
    verify_issue "$url" false || { notice "GitHub readback was incomplete; publication state UNKNOWN and local report retained at $REPORT_DIR"; return 1; }
  else
    jq -e --argjson number "$issue_number" --arg login "$GH_LOGIN" '.[] | select(.number == $number and .author.login == $login)' "$REPORT_DIR/open-issues.json" >/dev/null || { notice "Selected issue is no longer eligible; local report retained at $REPORT_DIR"; return 1; }
    gh issue view "$issue_number" --repo "$REPORT_REPOSITORY" --json number,state,author,url >"$REPORT_DIR/selected-issue.json" || { notice "Selected issue could not be revalidated; local report retained at $REPORT_DIR"; return 1; }
    jq -e --argjson number "$issue_number" --arg login "$GH_LOGIN" '.number == $number and .state == "OPEN" and .author.login == $login and (.url | type == "string" and test("^https://github\\.com/paranjko/external-test-lab/issues/[1-9][0-9]*$"))' "$REPORT_DIR/selected-issue.json" >/dev/null || { notice "Selected issue is no longer eligible; local report retained at $REPORT_DIR"; return 1; }
    gh issue comment "$issue_number" --repo "$REPORT_REPOSITORY" --body-file "$REPORT_DIR/report.md" "${attachment_args[@]}" >/dev/null || { notice "GitHub comment creation failed; publication state UNKNOWN and local report retained at $REPORT_DIR"; return 1; }
    url="$(jq -r '.url' "$REPORT_DIR/selected-issue.json")"
    verify_issue "$url" true || { notice "GitHub readback was incomplete; publication state UNKNOWN and local report retained at $REPORT_DIR"; return 1; }
  fi
  printf 'publication_state=VERIFIED\npublication_url=%s\n' "$PUBLICATION_URL" >"$REPORT_DIR/publication.env"
  chmod 0600 "$REPORT_DIR/publication.env"
  printf 'Published and verified: %s\nLocal report retained: %s\n' "$PUBLICATION_URL" "$REPORT_DIR"
}

select_failure
mkdir -p "$REPORTING_ROOT/reports"
REPORT_DIR="$(mktemp -d "$REPORTING_ROOT/reports/report.XXXXXX")"
chmod 0700 "$REPORT_DIR"
write_report "$REPORT_DIR"
archive_report "$REPORT_DIR"
printf 'Local sanitized report: %s\nLocal archive: %s\n' "$REPORT_DIR" "$ARCHIVE_PATH"
publish
