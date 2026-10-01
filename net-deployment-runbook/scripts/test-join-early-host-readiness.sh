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
case "${READINESS_RESULT:?}" in
  reboot) printf 'REBOOT_REQUIRED pending_host_package_updates\n'; exit 194 ;;
  action) printf 'OPERATOR_ACTION_REQUIRED package_manager_unresolved\n'; exit 195 ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/ssh"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'network access must not follow a failed Host readiness check' >&2
exit 97
EOF
chmod 0755 "$tmp/bin/curl"

run_case() {
  local name="$1" expected_rc="$2" operator rc result
  operator="$tmp/$name-operator"
  if READINESS_RESULT="$name" JOIN_SSH_LOG="$tmp/$name.ssh" PATH="$tmp/bin:$PATH" GDC_HOME="$operator" \
    "$ROOT/gdc.sh" host join --public-host validator.example.test validator-a >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "$name readiness check unexpectedly continued JOIN" >&2
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" -eq "$expected_rc" ]]
  result="$(find "$operator" -path '*/join-validator-a/join-result.v1.json' -type f -print -quit)"
  [[ -n "$result" ]]
  jq -e --argjson rc "$expected_rc" '
    .outcome == "refused" and .phase == "profile" and .category == "host" and
    .reason == "join_preflight_failed" and .exit_code == $rc and
    .mutation == "none" and .signer_state == "absent" and .resume == "new_profile"
  ' "$result" >/dev/null
}

run_case reboot 194 REBOOT_REQUIRED
run_case action 195 OPERATOR_ACTION_REQUIRED

printf 'PASS JOIN stops on known Host readiness prerequisites before network observation\n'
