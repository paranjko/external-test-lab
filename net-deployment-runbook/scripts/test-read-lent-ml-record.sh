#!/usr/bin/env bash
# Exercise the real remote reader through a closed SSH transport. A dangling
# ownership symlink is unsafe, not proof that a validator was never lent.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
remote_root="$tmp/remote"
mkdir -p "$tmp/bin" "$remote_root/srv/dai/deploy/.node-control"

cat >"$tmp/bin/sudo" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == -n ]] && shift
exec "$@"
SH
cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == *'gdc-lent-ml-record'* ]] || exit 91
remote_script="$(cat)"
printf '%s\n' "$remote_script" \
  | sed "s|/srv/dai|$GDC_TEST_REMOTE_ROOT/srv/dai|g" \
  | PATH="$GDC_TEST_BIN:$PATH" bash -s -- gdc-lent-ml-record
SH
chmod 0755 "$tmp/bin/sudo" "$tmp/bin/ssh"

record="$remote_root/srv/dai/deploy/.node-control/lent-ml.json"
run_reader() {
  PATH="$tmp/bin:$PATH" GDC_TEST_BIN="$tmp/bin" GDC_TEST_REMOTE_ROOT="$remote_root" \
    bash "$ROOT/scripts/read-lent-ml-record.sh" fixture
}

# Explicit absence is the sole ordinary-start outcome.
rc=0
run_reader >"$tmp/absent.out" 2>"$tmp/absent.err" || rc=$?
[[ "$rc" == 10 && ! -s "$tmp/absent.out" && ! -s "$tmp/absent.err" ]]

printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"gpu.example.test","node_id":"fixture:parent--donor"}' >"$record"
run_reader >"$tmp/valid.out"
jq -e '.parent_alias == "parent" and .endpoint == "gpu.example.test"' "$tmp/valid.out" >/dev/null

# A regular file with invalid content is not a safe absence. It must keep the
# donor stopped just as a transport or filesystem failure does.
printf '%s\n' '{}' >"$record"
rc=0
run_reader >"$tmp/malformed.out" 2>"$tmp/malformed.err" || rc=$?
[[ "$rc" == 195 && ! -s "$tmp/malformed.out" ]]
[[ "$(<"$tmp/malformed.err")" == 'OPERATOR ACTION REQUIRED cannot validate the retained ML lending record for fixture; leave the donor stopped and repair the record before rerunning gdc host start fixture' ]]

# `-e` is false for a dangling symlink. It must still produce the bounded
# unreadable-record refusal instead of reaching ordinary validator start.
rm -f -- "$record"
ln -s /missing/lent-ml.json "$record"
rc=0
run_reader >"$tmp/dangling.out" 2>"$tmp/dangling.err" || rc=$?
[[ "$rc" == 195 && ! -s "$tmp/dangling.out" ]]
[[ "$(<"$tmp/dangling.err")" == 'OPERATOR ACTION REQUIRED cannot read the retained ML lending record for fixture; leave the donor stopped and restore SSH access before rerunning gdc host start fixture' ]]

printf 'PASS lending reader distinguishes a confirmed absence from a dangling ownership record\n'
