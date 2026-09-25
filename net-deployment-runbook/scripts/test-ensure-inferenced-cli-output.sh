#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runbook/scripts" "$tmp/payload" "$tmp/home" "$tmp/bin"
cp "$ROOT/scripts/ensure-inferenced-cli.sh" "$tmp/runbook/scripts/ensure-inferenced-cli.sh"
cp "$ROOT/scripts/inferenced.sh" "$tmp/runbook/scripts/inferenced.sh"

cp "$ROOT/scripts/lib.sh" "$tmp/runbook/scripts/lib.sh"
cp "$ROOT/scripts/lib-lock.sh" "$tmp/runbook/scripts/lib-lock.sh"
(
  GDC_HOME="$tmp/actual-operator-root"
  # shellcheck source=/dev/null
  source "$tmp/runbook/scripts/lib.sh"
  init_gdc_data_root
  select_node_data_home node8
  printf '%s\n%s\n' "$GDC_INTERNAL_DATA_ROOT" "$GDC_HOME"
) >"$tmp/actual-root.out"
[[ "$(sed -n '1p' "$tmp/actual-root.out")" == "$tmp/actual-operator-root" ]]
[[ "$(sed -n '2p' "$tmp/actual-root.out")" == "$tmp/actual-operator-root/node8" ]]
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
[[ -x "$tmp/gdc-home/bin/9.9.9/inferenced" ]]
grep -Fq 'INSTALL pinned inferenced release=9.9.9 platform=LINUX_AMD64' "$tmp/profile.stderr"

# A changed Join Profile for the same verified artifact reuses one shared
# version-bound executable without downloading or installing it again.
second_profile="$tmp/second-join-profile.json"
jq '.profile_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$tmp/join-profile.json" >"$second_profile"
GDC_HOME="$tmp/gdc-home" \
GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" >"$tmp/second.stdout" 2>"$tmp/second.stderr"
[[ -x "$tmp/gdc-home/bin/9.9.9/inferenced" ]]
! grep -Fq 'WAIT download pinned inferenced CLI' "$tmp/second.stderr"
[[ "$(sha256sum "$tmp/gdc-home/artifacts/inferenced/$archive_sha/inferenced.zip" | awk '{print $1}')" == "$archive_sha" ]]

# A prior shared-cache implementation could leave the exact verified binary
# without metadata. Adopt only that byte-identical binary and never overwrite
# it merely because its reported version looks compatible.
rm "$tmp/gdc-home/bin/9.9.9/artifact.env"
legacy_binary_sha="$(sha256sum "$tmp/gdc-home/bin/9.9.9/inferenced" | awk '{print $1}')"
GDC_HOME="$tmp/gdc-home" \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" \
  >"$tmp/adopt.stdout" 2>"$tmp/adopt.stderr"
[[ -f "$tmp/gdc-home/bin/9.9.9/artifact.env" ]]
[[ "$(sha256sum "$tmp/gdc-home/bin/9.9.9/inferenced" | awk '{print $1}')" == "$legacy_binary_sha" ]]
grep -Fq 'PASS adopted verified legacy inferenced CLI' "$tmp/adopt.stdout"
! grep -Fq 'WAIT download pinned inferenced CLI' "$tmp/adopt.stderr"

rm "$tmp/gdc-home/bin/9.9.9/artifact.env"
cp "$tmp/gdc-home/bin/9.9.9/inferenced" "$tmp/adopted-inferenced.backup"
printf '\n# not the archived binary\n' >>"$tmp/gdc-home/bin/9.9.9/inferenced"
untrusted_binary_sha="$(sha256sum "$tmp/gdc-home/bin/9.9.9/inferenced" | awk '{print $1}')"
if GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" \
  >"$tmp/adopt-tamper.out" 2>"$tmp/adopt-tamper.err"; then
  echo 'unverified metadata-free inferenced CLI was adopted' >&2; exit 1
fi
grep -Fq 'conflicting or tampered shared inferenced CLI' "$tmp/adopt-tamper.err"
[[ ! -e "$tmp/gdc-home/bin/9.9.9/artifact.env" ]]
[[ "$(sha256sum "$tmp/gdc-home/bin/9.9.9/inferenced" | awk '{print $1}')" == "$untrusted_binary_sha" ]]
install -m 0755 "$tmp/adopted-inferenced.backup" "$tmp/gdc-home/bin/9.9.9/inferenced"
GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile"

# A cached executable is verified by its own recorded checksum, not merely by
# version output. Tamper and same-version artifact conflicts fail closed.
cp "$tmp/gdc-home/bin/9.9.9/inferenced" "$tmp/shared-inferenced.backup"
printf '\n# tampered\n' >>"$tmp/gdc-home/bin/9.9.9/inferenced"
if GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" >"$tmp/tamper.out" 2>"$tmp/tamper.err"; then
  echo 'tampered shared inferenced CLI was reused' >&2; exit 1
fi
grep -Fq 'conflicting or tampered shared inferenced CLI' "$tmp/tamper.err"
install -m 0755 "$tmp/shared-inferenced.backup" "$tmp/gdc-home/bin/9.9.9/inferenced"

conflict_profile="$tmp/conflict-profile.json"
jq '.spec.components.core.installation.binary.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$second_profile" >"$conflict_profile"
if GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$conflict_profile" >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  echo 'same-version conflicting artifact overwrote the shared CLI' >&2; exit 1
fi
grep -Fq 'conflicting or tampered shared inferenced CLI' "$tmp/conflict.err"

cp "$tmp/gdc-home/bin/9.9.9/artifact.env" "$tmp/artifact.env.backup"
sed -i 's/platform=LINUX_AMD64/platform=LINUX_ARM64/' "$tmp/gdc-home/bin/9.9.9/artifact.env"
if GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" >"$tmp/platform.out" 2>"$tmp/platform.err"; then
  echo 'same-version platform conflict was accepted' >&2; exit 1
fi
grep -Fq 'conflicting or tampered shared inferenced CLI' "$tmp/platform.err"
cp "$tmp/artifact.env.backup" "$tmp/gdc-home/bin/9.9.9/artifact.env"

# A held install lock respects a small configured bound; the production
# default is derived from the full curl retry budget rather than this value.
mkdir -m 0700 "$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d"
printf '%s\n' "$$" >"$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d/pid"
if GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_LOCK_TIMEOUT_SECONDS=1 GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" >"$tmp/lock.out" 2>"$tmp/lock.err"; then
  echo 'bounded install lock unexpectedly succeeded while held' >&2; exit 1
fi
grep -Fq 'timed out waiting for inferenced CLI install lock' "$tmp/lock.err"
rm -f "$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d/pid"
rmdir "$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d"

# A parallel installer can observe the directory after mkdir(2), but before
# its owner writes pid. This short interval is initialization, not corruption.
mkdir -m 0700 "$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d"
(
  sleep 1
  printf '%s\n' "$$" >"$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d/pid"
  sleep 1
  rm -f "$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d/pid"
  rmdir "$tmp/gdc-home/bin/.locks/inferenced-9.9.9.lock.d"
) &
initializing_lock_pid=$!
GDC_HOME="$tmp/gdc-home" GDC_INFERENCED_CLI_LOCK_TIMEOUT_SECONDS=4 GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" \
  >"$tmp/initializing-lock.out" 2>"$tmp/initializing-lock.err"
wait "$initializing_lock_pid"
[[ ! -s "$tmp/initializing-lock.out" ]]
! grep -Fq 'lock directory is incomplete or unsafe' "$tmp/initializing-lock.err"

# A symlinked final version directory is refused without modifying its target.
symlink_root="$tmp/symlink-root"
mkdir -p "$symlink_root/bin" "$tmp/external-target"
printf 'preserve\n' >"$tmp/external-target/marker"
ln -s "$tmp/external-target" "$symlink_root/bin/9.9.9"
if GDC_INTERNAL_DATA_ROOT="$symlink_root" GDC_HOME="$symlink_root/node8" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" >"$tmp/symlink.out" 2>"$tmp/symlink.err"; then
  echo 'symlinked shared version directory was accepted' >&2; exit 1
fi
grep -Fq 'must not be a symlink' "$tmp/symlink.err"
grep -Fxq preserve "$tmp/external-target/marker"
[[ "$(find "$tmp/external-target" -maxdepth 1 -type f | wc -l)" == 1 ]]

# Validate the unpacked executable before publishing the shared directory.
sed 's/v9\.9\.9/v8.8.8/' "$tmp/payload/inferenced" >"$tmp/wrong-inferenced"
chmod 0755 "$tmp/wrong-inferenced"
TEST_PAYLOAD="$tmp/wrong-inferenced" TEST_ARCHIVE="$tmp/wrong.zip" python3 - <<'PY'
import os, zipfile
info = zipfile.ZipInfo("inferenced")
info.external_attr = 0o100755 << 16
with open(os.environ["TEST_PAYLOAD"], "rb") as source:
    payload = source.read()
with zipfile.ZipFile(os.environ["TEST_ARCHIVE"], "w") as archive:
    archive.writestr(info, payload)
PY
wrong_sha="$(sha256sum "$tmp/wrong.zip" | awk '{print $1}')"
jq --arg url "file://$tmp/wrong.zip" --arg sha "$wrong_sha" \
  '.spec.components.core.installation.binary = {url:$url,sha256:$sha}' "$tmp/join-profile.json" >"$tmp/wrong-profile.json"
wrong_root="$tmp/wrong-root"
if GDC_INTERNAL_DATA_ROOT="$wrong_root" GDC_HOME="$wrong_root/node8" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$tmp/wrong-profile.json" >"$tmp/wrong.out" 2>"$tmp/wrong.err"; then
  echo 'wrong-version archive was published' >&2; exit 1
fi
grep -Fq 'does not report required version 9.9.9' "$tmp/wrong.err"
[[ ! -e "$wrong_root/bin/9.9.9" ]] || { echo 'wrong-version failure left a final shared directory' >&2; exit 1; }

# A new alias can migrate a verified archive from one direct sibling node
# cache without downloading or touching any legacy cache/key material.
migration_root="$tmp/migration-root"
mkdir -p "$migration_root/node7/artifacts/inferenced/$archive_sha"
cp "$tmp/inferenced.zip" "$migration_root/node7/artifacts/inferenced/$archive_sha/inferenced.zip"
jq '.spec.components.core.installation.binary.url = "file:///does/not/exist.zip"' \
  "$tmp/join-profile.json" >"$tmp/migration-profile.json"
GDC_INTERNAL_DATA_ROOT="$migration_root" GDC_HOME="$migration_root/node8" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$tmp/migration-profile.json" \
  >"$tmp/migration.out" 2>"$tmp/migration.err"
[[ -x "$migration_root/bin/9.9.9/inferenced" ]]
cmp -s "$tmp/inferenced.zip" "$migration_root/node7/artifacts/inferenced/$archive_sha/inferenced.zip"
! grep -Fq 'WAIT download pinned inferenced CLI' "$tmp/migration.err"

# Two node-scoped homes installing concurrently share one operator-root cache.
shared_root="$tmp/shared-root"
GDC_INTERNAL_DATA_ROOT="$shared_root" GDC_HOME="$tmp/node-a" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$tmp/join-profile.json" >"$tmp/parallel-a.out" 2>"$tmp/parallel-a.err" &
pid_a=$!
GDC_INTERNAL_DATA_ROOT="$shared_root" GDC_HOME="$tmp/node-b" GDC_INFERENCED_CLI_QUIET=true \
  "$tmp/runbook/scripts/ensure-inferenced-cli.sh" --join-profile "$second_profile" >"$tmp/parallel-b.out" 2>"$tmp/parallel-b.err" &
pid_b=$!
wait "$pid_a"; wait "$pid_b"
[[ -x "$shared_root/bin/9.9.9/inferenced" ]]
[[ "$(find "$shared_root/bin" -type f -name inferenced | wc -l)" == 1 ]]

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
PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/gdc-home" GDC_JOIN_PROFILE="$second_profile" \
  "$tmp/runbook/scripts/inferenced.sh" version >"$tmp/confirmed-profile-wrapper.out"
grep -Fxq 'inferenced v9.9.9' "$tmp/confirmed-profile-wrapper.out"
grep -Fq 'ensure-inferenced-cli.sh" --allow-expired --join-profile "$GDC_JOIN_PROFILE"' "$ROOT/01-identities-genesis/create-cold-accounts.sh"

printf 'PASS inferenced installation binds downstream CLI calls to the exact Join Profile\n'
