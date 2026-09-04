#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runbook/scripts" "$tmp/payload" "$tmp/home" "$tmp/bin"
cp "$ROOT/scripts/ensure-inferenced-cli.sh" "$tmp/runbook/scripts/ensure-inferenced-cli.sh"
cp "$ROOT/scripts/inferenced.sh" "$tmp/runbook/scripts/inferenced.sh"

cat >"$tmp/runbook/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
step() { printf '\n== %s ==\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
STATE="${GDC_HOME:-${HOME:?}/.gdc-data}/state"
SH
cat >"$tmp/runbook/scripts/profile.sh" <<'SH'
#!/usr/bin/env bash
load_profiles() {
  GDC_RELEASE_PROFILE=test
  GONKA_RELEASE=9.9.9
  INFERENCED_OPERATOR_URL_LINUX_AMD64="file://$TEST_INFERENCED_ARCHIVE"
  INFERENCED_OPERATOR_SHA256_LINUX_AMD64="$TEST_INFERENCED_ARCHIVE_SHA256"
  export GDC_RELEASE_PROFILE GONKA_RELEASE
  export INFERENCED_OPERATOR_URL_LINUX_AMD64 INFERENCED_OPERATOR_SHA256_LINUX_AMD64
}
SH
cat >"$tmp/runbook/scripts/join-profile.sh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == validate && ( -r "${2:-}" || ( "${2:-}" == --allow-expired && -r "${3:-}" ) ) ]] || exit 2
profile="${2:-}"
[[ "$profile" == --allow-expired ]] && profile="${3:-}"
if [[ "${2:-}" != --allow-expired ]] && [[ "$(jq -r .valid_until "$profile" 2>/dev/null)" == 2000-* ]]; then
  exit 1
fi
SH
chmod +x "$tmp/runbook/scripts/join-profile.sh"
cat >"$tmp/payload/inferenced" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == version || "${3:-}" == version ]]; then
  printf 'inferenced v9.9.9\n'
  exit 0
fi
printf '{}\n'
SH
chmod +x "$tmp/payload/inferenced"
TEST_PAYLOAD="$tmp/payload/inferenced" TEST_ARCHIVE="$tmp/inferenced.zip" python3 - <<'PY'
import os
import zipfile

info = zipfile.ZipInfo("inferenced")
info.external_attr = 0o100755 << 16
with open(os.environ["TEST_PAYLOAD"], "rb") as source:
    payload = source.read()
with zipfile.ZipFile(os.environ["TEST_ARCHIVE"], "w") as archive:
    archive.writestr(info, payload)
PY
archive_sha="$(sha256sum "$tmp/inferenced.zip" | awk '{print $1}')"

TEST_INFERENCED_ARCHIVE="$tmp/inferenced.zip" \
TEST_INFERENCED_ARCHIVE_SHA256="$archive_sha" \
HOME="$tmp/home" \
GDC_INFERENCED_BIN_DIR="$tmp/bin" \
GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" >"$tmp/stdout" 2>"$tmp/stderr"

[[ ! -s "$tmp/stdout" ]] || {
  echo 'quiet inferenced installation contaminated command stdout' >&2
  sed -n '1,20p' "$tmp/stdout" >&2
  exit 1
}
grep -Fq 'INSTALL pinned inferenced release=9.9.9 platform=LINUX_AMD64' "$tmp/stderr"
"$tmp/bin/inferenced" version | grep -Fq 'v9.9.9'

cat >"$tmp/join-profile.json" <<EOF
{"profile_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spec":{"target":{"platform":"linux-amd64"},"components":{"core":{"expected_runtime":{"version":"9.9.9","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"installation":{"binary":{"url":"file://$tmp/inferenced.zip","sha256":"$archive_sha"}}}}}}
EOF
GDC_HOME="$tmp/gdc-home" \
GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$tmp/join-profile.json" >"$tmp/profile.stdout" 2>"$tmp/profile.stderr"
[[ -x "$tmp/gdc-home/bin/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/inferenced" ]]
grep -Fq 'INSTALL pinned inferenced release=9.9.9 platform=LINUX_AMD64' "$tmp/profile.stderr"

# Post-mutation consumers keep the immutable profile/hash contract but may
# continue using the retained profile after its short freshness window.
expired_profile="$tmp/expired-profile.json"
jq '.valid_until = "2000-01-01T00:00:00Z"' "$tmp/join-profile.json" >"$expired_profile"
if GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$expired_profile" >"$tmp/expired-strict.out" 2>"$tmp/expired-strict.err"; then
  echo 'expired JOIN profile unexpectedly passed strict inferenced validation' >&2
  exit 1
fi
GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --allow-expired --join-profile "$expired_profile" >"$tmp/expired.out" 2>"$tmp/expired.err"

# The generated profile must take precedence over a compatible-looking binary
# from PATH for every downstream query and transaction wrapper.
cat >"$tmp/bin/inferenced" <<'SH'
#!/usr/bin/env bash
printf 'wrong-path-cli\n'
SH
chmod +x "$tmp/bin/inferenced"
PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/gdc-home" GDC_JOIN_PROFILE="$tmp/join-profile.json" \
  "$tmp/runbook/scripts/inferenced.sh" version >"$tmp/profile-wrapper.out"
grep -Fxq 'inferenced v9.9.9' "$tmp/profile-wrapper.out"
! grep -Fq wrong-path-cli "$tmp/profile-wrapper.out"
grep -Fq 'ensure-inferenced-cli.sh" --join-profile "$GDC_JOIN_PROFILE"' "$ROOT/01-identities-genesis/create-cold-accounts.sh"

printf 'PASS inferenced installation binds downstream CLI calls to the exact Join Profile\n'
