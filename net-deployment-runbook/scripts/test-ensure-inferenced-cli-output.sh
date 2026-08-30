#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runbook/scripts" "$tmp/payload" "$tmp/home" "$tmp/bin"
cp "$ROOT/scripts/ensure-inferenced-cli.sh" "$tmp/runbook/scripts/ensure-inferenced-cli.sh"

cat >"$tmp/runbook/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
step() { printf '\n== %s ==\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
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
cat >"$tmp/payload/inferenced" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then
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

printf 'PASS quiet inferenced installation preserves machine-readable stdout\n'
