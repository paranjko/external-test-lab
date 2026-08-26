#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 13 ]] || die 'usage: publish-running-host-recovery.sh NODE ADDRESS RUNTIME_ID RUN_ID RUNTIME_FILE JOIN_STATE_FILE JOINED_MARKER EVIDENCE_SOURCE EVIDENCE_TARGET RECEIPT_SOURCE VERDICT_SOURCE RECEIPT_TARGET VERDICT_TARGET'

node="$1"
address="$2"
runtime_id="$3"
run_id="$4"
runtime_file="$5"
join_state_file="$6"
joined_marker="$7"
evidence_source="$8"
evidence_target="$9"
receipt_source="${10}"
verdict_source="${11}"
receipt_target="${12}"
verdict_target="${13}"

[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'recovery publication node is invalid'
[[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] || die 'recovery publication participant address is invalid'
[[ "$runtime_id" == *":$address" && "$runtime_id" != *$'\n'* ]] || die 'recovery publication runtime identity is invalid'
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'recovery publication run ID is invalid'

targets=("$runtime_file" "$join_state_file" "$joined_marker" "$receipt_target" "$verdict_target")
for target in "${targets[@]}"; do
  [[ "$target" == /* && "$target" != / ]] || die 'recovery publication target is not an absolute bounded path'
  [[ ! -L "$target" ]] || die "recovery publication target is a symbolic link: $target"
  [[ ! -e "$target" || -f "$target" ]] || die "recovery publication target is not a regular file: $target"
done
[[ "$evidence_source" == /* && -d "$evidence_source" && ! -L "$evidence_source" ]] \
  || die 'recovery decision evidence source is invalid'
[[ "$evidence_target" == /* && "$evidence_target" != / && ! -L "$evidence_target" ]] \
  || die 'recovery decision evidence target is invalid'
[[ ! -e "$evidence_target" || -d "$evidence_target" ]] \
  || die 'recovery decision evidence target has the wrong type'
for source in "$receipt_source" "$verdict_source"; do
  [[ "$source" == /* && -f "$source" && ! -L "$source" && -s "$source" ]] \
    || die "recovery publication source is invalid: $source"
done

evidence_files=(decision-boundary.marker status.json participant.json validator-set.json \
  commit.json runtime.json synchronization.json freshness.json)
snapshot_names=(status participant validator_set commit runtime synchronization)
snapshot_files=(status.json participant.json validator-set.json commit.json runtime.json synchronization.json)
for evidence_file in "${evidence_files[@]}"; do
  source="$evidence_source/$evidence_file"
  [[ -f "$source" && ! -L "$source" && -s "$source" ]] \
    || die "recovery decision evidence is incomplete: $evidence_file"
done
freshness="$evidence_source/freshness.json"
jq -e '
  def safe_uint: type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
  . as $freshness
  | type == "object" and .matched == true
  and (.evaluated_at_unix | safe_uint)
  and (.not_before_unix | safe_uint)
  and (.max_age_seconds | safe_uint) and .max_age_seconds > 0 and .max_age_seconds <= 3600
  and .not_before_unix <= .evaluated_at_unix
  and (.evaluated_at_unix - .not_before_unix) <= .max_age_seconds
  and (.boundary_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and (.snapshots | type == "object")
  and ((.snapshots | keys | sort)
    == ["commit","participant","runtime","status","synchronization","validator_set"])
  and all(.snapshots[];
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.mtime_unix | safe_uint)
    and .mtime_unix >= $freshness.not_before_unix
    and .mtime_unix <= $freshness.evaluated_at_unix
    and ($freshness.evaluated_at_unix - .mtime_unix) <= $freshness.max_age_seconds)
' "$freshness" >/dev/null || die 'recovery decision freshness evidence is malformed'

publication_test_now_unix=''

current_publication_time() {
  local mode="${GDC_RECOVERY_PUBLICATION_TEST_MODE:-false}" now
  [[ "$mode" == true || "$mode" == false ]] \
    || die 'recovery publication test mode is invalid'
  if [[ -n "$publication_test_now_unix" ]]; then
    now="$publication_test_now_unix"
  elif [[ -n "${GDC_RECOVERY_PUBLICATION_NOW_UNIX:-}" ]]; then
    [[ "$mode" == true ]] || die 'recovery publication clock injection is test-only'
    now="$GDC_RECOVERY_PUBLICATION_NOW_UNIX"
  else
    now="$(date +%s)"
  fi
  [[ "$now" =~ ^(0|[1-9][0-9]{0,15})$ ]] \
    && ((10#$now <= 9007199254740991)) \
    || die 'recovery publication current time is invalid'
  printf '%s\n' "$now"
}

validate_freshness_window() {
  local now
  now="$(current_publication_time)"
  jq -e --argjson now "$now" '
    . as $freshness
    | .evaluated_at_unix <= $now
    and ($now - .evaluated_at_unix) <= .max_age_seconds
    and .not_before_unix <= $now
    and ($now - .not_before_unix) <= .max_age_seconds
    and all(.snapshots[];
      .mtime_unix <= $now and ($now - .mtime_unix) <= $freshness.max_age_seconds)
  ' "$freshness" >/dev/null \
    || die 'recovery decision freshness expired before publication'
}

advance_publication_test_clock_after() {
  local stage="$1" configured="${GDC_RECOVERY_PUBLICATION_TEST_ADVANCE_AFTER:-}"
  local evaluated_at max_age
  [[ -n "$configured" && "$configured" == "$stage" ]] || return 0
  evaluated_at="$(jq -er .evaluated_at_unix "$freshness")"
  max_age="$(jq -er .max_age_seconds "$freshness")"
  publication_test_now_unix=$((10#$evaluated_at + 10#$max_age + 1))
}

validate_bound_source() {
  local boundary_mtime expected_mtime expected_hash actual_hash index
  boundary_mtime="$(stat -c %Y -- "$evidence_source/decision-boundary.marker" 2>/dev/null)" \
    || die 'recovery decision boundary timestamp is unavailable at publication'
  [[ "$boundary_mtime" == "$(jq -er .not_before_unix "$freshness")" ]] \
    || die 'recovery decision boundary timestamp does not match freshness evidence'
  [[ "$(sha256sum "$evidence_source/decision-boundary.marker" | awk '{print $1}')" \
    == "$(jq -er .boundary_sha256 "$freshness")" ]] \
    || die 'recovery decision boundary hash does not match freshness evidence'
  for index in "${!snapshot_names[@]}"; do
    expected_hash="$(jq -er --arg name "${snapshot_names[$index]}" \
      '.snapshots[$name].sha256' "$freshness")"
    actual_hash="$(sha256sum "$evidence_source/${snapshot_files[$index]}" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] \
      || die "recovery decision ${snapshot_names[$index]} hash does not match freshness evidence"
    expected_mtime="$(jq -er --arg name "${snapshot_names[$index]}" \
      '.snapshots[$name].mtime_unix' "$freshness")"
    [[ "$(stat -c %Y -- "$evidence_source/${snapshot_files[$index]}" 2>/dev/null)" \
      == "$expected_mtime" ]] \
      || die "recovery decision ${snapshot_names[$index]} timestamp does not match freshness evidence"
    [[ "$evidence_source/${snapshot_files[$index]}" \
      -nt "$evidence_source/decision-boundary.marker" ]] \
      || die "recovery decision ${snapshot_names[$index]} no longer postdates the decision boundary"
  done
}

validate_freshness_window
validate_bound_source

jq -e --arg node "$node" --arg address "$address" --arg runtime_id "$runtime_id" \
  --arg evidence_bundle "$(basename "$evidence_target")" --slurpfile freshness "$freshness" '
  .schema_version == 1 and .verdict == "PASS" and .node == $node
  and .participant_address == $address and .runtime_id == $runtime_id
  and .decision_evidence_bundle == $evidence_bundle
  and .decision_evidence == $freshness[0]
  and .remote_identity_write == false
' "$receipt_source" >/dev/null || die 'recovery PASS receipt is malformed or belongs to another Host'
grep -qx '# Existing Host operator-state recovery: PASS' "$verdict_source" \
  || die 'recovery PASS verdict is malformed'

for target in "${targets[@]}" "$evidence_target"; do
  parent="$(dirname "$target")"
  [[ ! -L "$parent" ]] || die "recovery publication parent is a symbolic link: $parent"
  install -d -m 0700 "$parent"
  [[ -d "$parent" && ! -L "$parent" ]] || die "recovery publication parent is invalid: $parent"
done

lock_file="$(dirname "$joined_marker")/.${node}.recovery-publication.lock"
exec 9>"$lock_file"
flock -n 9 || die "another $node recovery publication is in progress"

if [[ -e "$runtime_file" ]]; then
  [[ -f "$runtime_file" && ! -L "$runtime_file" && -s "$runtime_file" ]] \
    || die 'existing runtime identity record is incomplete'
  existing_node="$(awk -F= '$1 == "node" {print $2; exit}' "$runtime_file")"
  existing_address="$(awk -F= '$1 == "participant_address" {print $2; exit}' "$runtime_file")"
  existing_runtime="$(awk -F= '$1 == "runtime_id" {print $2; exit}' "$runtime_file")"
  [[ "$existing_node" == "$node" && "$existing_address" == "$address" \
    && "$existing_runtime" == "$runtime_id" ]] \
    || die 'existing runtime identity record conflicts with the recovered Host'
fi

temporary_files=()
temporary_dirs=()
receipt_staged=''
verdict_staged=''
runtime_staged=''
join_staged=''
marker_staged=''
evidence_staged=''
cleanup() {
  local file directory
  for file in "${temporary_files[@]}"; do
    rm -f -- "$file"
  done
  for directory in "${temporary_dirs[@]}"; do
    rm -rf -- "$directory"
  done
}
trap cleanup EXIT INT TERM
umask 077

stage_file() {
  local target="$1" variable_name="$2" staged
  staged="$(mktemp "$(dirname "$target")/.${node}.recovery.XXXXXX")"
  chmod 0600 "$staged"
  temporary_files+=("$staged")
  printf -v "$variable_name" '%s' "$staged"
}

stage_file "$receipt_target" receipt_staged
stage_file "$verdict_target" verdict_staged
stage_file "$runtime_file" runtime_staged
stage_file "$join_state_file" join_staged
stage_file "$joined_marker" marker_staged
evidence_staged="$(mktemp -d "$(dirname "$evidence_target")/.${node}.recovery-evidence.XXXXXX")"
temporary_dirs+=("$evidence_staged")

install -m 0600 "$receipt_source" "$receipt_staged"
install -m 0600 "$verdict_source" "$verdict_staged"
for evidence_file in "${evidence_files[@]}"; do
  install -m 0600 "$evidence_source/$evidence_file" "$evidence_staged/$evidence_file"
done
{
  printf 'node=%s\n' "$node"
  printf 'participant_address=%s\n' "$address"
  printf 'runtime_id=%s\n' "$runtime_id"
  printf 'recorded_at=%s\n' "$(date -u +%FT%TZ)"
} >"$runtime_staged"
{
  printf 'node=%s\n' "$node"
  printf 'state=ACTIVE\n'
  printf 'observed_at=%s\n' "$(date -u +%FT%TZ)"
  printf 'run_id=%s\n' "$run_id"
  printf 'address=%s\n' "$address"
} >"$join_staged"
receipt_sha256="$(sha256sum "$receipt_staged" | awk '{print $1}')"
{
  printf 'schema_version=1\n'
  printf 'node=%s\n' "$node"
  printf 'run_id=%s\n' "$run_id"
  printf 'receipt_sha256=%s\n' "$receipt_sha256"
} >"$marker_staged"

# Re-read the clock and bound source immediately before the first durable
# publication. Also verify that every staged decision file is the frozen one.
validate_freshness_window
validate_bound_source
for evidence_file in "${evidence_files[@]}"; do
  cmp -s "$evidence_source/$evidence_file" "$evidence_staged/$evidence_file" \
    || die "staged recovery decision evidence changed before publication: $evidence_file"
done

case "${GDC_RECOVERY_PUBLICATION_TEST_STOP_AFTER:-}" in
  ''|evidence|receipt|verdict|runtime|join_state|joined) ;;
  *) die 'unknown recovery publication test interruption stage' ;;
esac
case "${GDC_RECOVERY_PUBLICATION_TEST_ADVANCE_AFTER:-}" in
  ''|evidence|receipt|verdict|runtime|join_state) ;;
  *) die 'unknown recovery publication test clock-advance stage' ;;
esac
if [[ -n "${GDC_RECOVERY_PUBLICATION_TEST_ADVANCE_AFTER:-}" \
  && "${GDC_RECOVERY_PUBLICATION_TEST_MODE:-false}" != true ]]; then
  die 'recovery publication clock advance is test-only'
fi

publish_one() {
  local source="$1" target="$2" stage="$3"
  mv -f -- "$source" "$target"
  advance_publication_test_clock_after "$stage"
  [[ "${GDC_RECOVERY_PUBLICATION_TEST_STOP_AFTER:-}" != "$stage" ]] || exit 97
}

# The joined marker is the only commit point. Every preceding write is atomic,
# deterministic and safe to repeat after interruption.
if [[ -e "$evidence_target" ]]; then
  [[ -d "$evidence_target" && ! -L "$evidence_target" ]] \
    || die 'existing recovery decision evidence target is invalid'
  diff -qr "$evidence_staged" "$evidence_target" >/dev/null 2>&1 \
    || die 'existing recovery decision evidence conflicts with the current frozen decision'
  rm -rf -- "$evidence_staged"
else
  mv -- "$evidence_staged" "$evidence_target"
fi
advance_publication_test_clock_after evidence
[[ "${GDC_RECOVERY_PUBLICATION_TEST_STOP_AFTER:-}" != evidence ]] || exit 97
publish_one "$receipt_staged" "$receipt_target" receipt
publish_one "$verdict_staged" "$verdict_target" verdict
publish_one "$runtime_staged" "$runtime_file" runtime
publish_one "$join_staged" "$join_state_file" join_state

# Rebind the durable evidence and receipt, then read the clock as the final
# operation before the joined marker makes PASS irreversible.
for evidence_file in "${evidence_files[@]}"; do
  cmp -s "$evidence_source/$evidence_file" "$evidence_target/$evidence_file" \
    || die "published recovery decision evidence changed before commit: $evidence_file"
done
validate_bound_source
[[ "$(sha256sum "$receipt_target" | awk '{print $1}')" == "$receipt_sha256" ]] \
  || die 'published recovery PASS receipt changed before commit'
validate_freshness_window
mv -f -- "$marker_staged" "$joined_marker"
[[ "${GDC_RECOVERY_PUBLICATION_TEST_STOP_AFTER:-}" != joined ]] || exit 97

trap - EXIT INT TERM
cleanup
