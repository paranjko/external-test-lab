#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runbook/scripts" "$tmp/runbook/profiles/releases" "$tmp/payload" "$tmp/home" "$tmp/bin"
cp "$ROOT/scripts/ensure-inferenced-cli.sh" "$tmp/runbook/scripts/ensure-inferenced-cli.sh"
cp "$ROOT/scripts/inferenced.sh" "$tmp/runbook/scripts/inferenced.sh"
cp "$ROOT/scripts/portable.sh" "$tmp/runbook/scripts/portable.sh"

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
# `zip` is part of the stock macOS command-line tools and preserves the
# executable bit. Do not make Python a prerequisite of the local portability
# test itself.
(cd "$tmp/payload" && zip -q "$tmp/inferenced.zip" inferenced)
if command -v sha256sum >/dev/null 2>&1; then
  archive_sha="$(sha256sum "$tmp/inferenced.zip" | awk '{print $1}')"
else
  archive_sha="$(shasum -a 256 "$tmp/inferenced.zip" | awk '{print $1}')"
fi
cat >"$tmp/runbook/profiles/releases/test.lock" <<EOF
GONKA_RELEASE=9.9.9
INFERENCED_OPERATOR_URL_LINUX_AMD64=file://$tmp/inferenced.zip
INFERENCED_OPERATOR_SHA256_LINUX_AMD64=$archive_sha
INFERENCED_OPERATOR_URL_DARWIN_ARM64=file://$tmp/inferenced.zip
INFERENCED_OPERATOR_SHA256_DARWIN_ARM64=$archive_sha
EOF

# This fixture exercises the generated Linux Host profile on every CI OS. Do
# not let the runner's own platform choose a non-existent fixture artifact.
mkdir -p "$tmp/linux-platform-bin"
cat >"$tmp/linux-platform-bin/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' x86_64 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/linux-platform-bin/uname"
export PATH="$tmp/linux-platform-bin:$PATH"

TEST_INFERENCED_ARCHIVE="$tmp/inferenced.zip" \
TEST_INFERENCED_ARCHIVE_SHA256="$archive_sha" \
GDC_RELEASE_PROFILE=test \
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

# A generated Linux Host profile still installs the native operator CLI on a
# Darwin workstation. The target platform describes the remote host, not the
# local operator process.
mkdir -p "$tmp/platform-bin"
cat >"$tmp/platform-bin/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' Darwin ;;
  -m) printf '%s\n' arm64 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/platform-bin/uname"
if ! PATH="$tmp/platform-bin:$PATH" GDC_HOME="$tmp/darwin-platform-home" \
  GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$tmp/join-profile.json" >"$tmp/platform.stdout" 2>"$tmp/platform.stderr"; then
  echo 'Darwin JOIN profile failed to install native inferenced CLI' >&2
  exit 1
fi
grep -Fq 'INSTALL pinned inferenced release=9.9.9 platform=DARWIN_ARM64' "$tmp/platform.stderr"
[[ -x "$tmp/darwin-platform-home/bin/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/inferenced" ]]

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
grep -Fq 'ensure-inferenced-cli.sh" --allow-expired --join-profile "$GDC_JOIN_PROFILE"' "$ROOT/01-identities-genesis/create-cold-accounts.sh"

printf 'PASS inferenced installation binds downstream CLI calls to the exact Join Profile\n'
