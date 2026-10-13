#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$JOIN_SSH_LOG"
cat >/dev/null
if [[ "${READINESS_RESULT:?}" == target_not_clean && "${RETAIN_HOST_PREPARATION:-false}" != true && "$(wc -l <"$JOIN_SSH_LOG")" -eq 2 ]]; then
  printf 'JOIN_TARGET_NOT_CLEAN retained_node_state=/srv/dai/deploy\n'
  exit 196
fi
case "${READINESS_RESULT:?}" in
  reboot) printf 'REBOOT_REQUIRED pending_host_package_updates\n'; exit 194 ;;
  action) printf 'OPERATOR_ACTION_REQUIRED package_manager_unresolved\n'; exit 195 ;;
  target_not_clean) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/ssh"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -z "${JOIN_CURL_LOG:-}" ]] || printf '%s\n' "$*" >>"$JOIN_CURL_LOG"
printf '%s\n' 'network access must not follow a failed Host readiness check' >&2
exit 97
EOF
chmod 0755 "$tmp/bin/curl"

run_case() {
  local name="$1" expected_rc="$2" expected_message="$3" operator rc result
  operator="$tmp/$name-operator"
  if READINESS_RESULT="$name" JOIN_SSH_LOG="$tmp/$name.ssh" PATH="$tmp/bin:$PATH" GDC_HOME="$operator" \
    "$ROOT/gdc.sh" host join --public-host validator.example.test validator-a >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "$name readiness check unexpectedly continued JOIN" >&2
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" -eq "$expected_rc" ]]
  if [[ -n "$expected_message" ]]; then
    [[ "$(<"$tmp/$name.err")" == "$expected_message" ]]
    [[ ! -e "$operator/reporting/failures/latest-failure" ]]
  fi
  result="$(find "$operator" -path '*/join-validator-a/join-result.v1.json' -type f -print -quit)"
  [[ -n "$result" ]]
  jq -e --argjson rc "$expected_rc" '
    .outcome == "refused" and .phase == "profile" and .category == "host" and
    .reason == "join_preflight_failed" and .exit_code == $rc and
    .mutation == "none" and .signer_state == "absent" and .resume == "new_profile"
  ' "$result" >/dev/null
}

run_case reboot 194 ''
run_case action 195 'JOIN cannot continue because the Host package manager needs repair; resolve it and rerun the same command'

# Reset deliberately retains safe Host preparation, including /etc/gonka/host.env
# and its firewall. It must not be confused with a retained node deployment.
operator="$tmp/retained-host-preparation-operator"
if READINESS_RESULT=target_not_clean RETAIN_HOST_PREPARATION=true JOIN_SSH_LOG="$tmp/retained-host-preparation.ssh" \
  JOIN_CURL_LOG="$tmp/retained-host-preparation.curl" PATH="$tmp/bin:$PATH" GDC_HOME="$operator" \
  "$ROOT/gdc.sh" host join --public-host validator.example.test validator-a >"$tmp/retained-host-preparation.out" 2>"$tmp/retained-host-preparation.err"; then
  echo 'retained Host preparation unexpectedly completed JOIN' >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -ne 196 ]]
grep -Fq 'PASS JOIN target clean host=validator-a' "$tmp/retained-host-preparation.out"
[[ -s "$tmp/retained-host-preparation.curl" ]]

operator="$tmp/target-not-clean-operator"
if READINESS_RESULT=target_not_clean JOIN_SSH_LOG="$tmp/target-not-clean.ssh" PATH="$tmp/bin:$PATH" GDC_HOME="$operator" \
  "$ROOT/gdc.sh" host join --public-host validator.example.test validator-a >"$tmp/target-not-clean.out" 2>"$tmp/target-not-clean.err"; then
  echo 'non-clean target unexpectedly continued JOIN' >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 196 ]]
[[ "$(<"$tmp/target-not-clean.err")" == 'JOIN cannot continue because the Host retains state from an earlier GDC preparation' ]]
[[ ! -e "$operator/reporting/failures/latest-failure" ]]
result="$(find "$operator" -path '*/join-validator-a/join-result.v1.json' -type f -print -quit)"
[[ -n "$result" ]]
jq -e '
  .outcome == "refused" and .phase == "profile" and .category == "host" and
  .reason == "join_preflight_failed" and .exit_code == 196 and
  .mutation == "none" and .signer_state == "absent" and .resume == "new_profile"
' "$result" >/dev/null

printf 'PASS JOIN stops on known Host readiness prerequisites before network observation\n'
