#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d /tmp/gdc-test-release-target.XXXXXX)"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

cat >"$temporary/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *'/git/ref/tags/'*)
    printf '{"object":{"type":"tag","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
    ;;
  *'/git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'*)
    printf '{"object":{"type":"commit","sha":"%s"}}\n' "$TEST_RELEASE_TARGET"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$temporary/gh"

expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TEST_RELEASE_TARGET="$expected" PATH="$temporary:$PATH" \
  "$ROOT/scripts/verify-candidate-release-target.sh" owner/repository \
    lab-candidate/v2026.08.25-rc.0 "$expected" >/dev/null

set +e
TEST_RELEASE_TARGET=cccccccccccccccccccccccccccccccccccccccc PATH="$temporary:$PATH" \
  "$ROOT/scripts/verify-candidate-release-target.sh" owner/repository \
    lab-candidate/v2026.08.25-rc.0 "$expected" >"$temporary/stale.out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]
grep -Fq 'candidate release target mismatch' "$temporary/stale.out"

printf 'PASS candidate release target binding\n'
