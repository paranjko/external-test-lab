#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$ROOT/02-node/api-entrypoint.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

mkdir -p "$temporary/bin" "$temporary/work"
cat >"$temporary/bin/cosmovisor" <<'EOF'
#!/bin/sh
printf 'COSMOVISOR %s\n' "$*"
EOF
cat >"$temporary/work/init-docker.sh" <<'EOF'
#!/bin/sh
printf 'INIT\n'
EOF
chmod 0755 "$temporary/bin/cosmovisor" "$temporary/work/init-docker.sh"

first_home="$temporary/first"
mkdir -p "$first_home"
first_output="$(cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$first_home")"
[[ "$first_output" == INIT ]]

current_home="$temporary/current"
mkdir -p "$current_home/cosmovisor/upgrades/v0.2.16/bin"
cat >"$current_home/cosmovisor/upgrades/v0.2.16/bin/decentralized-api" <<'EOF'
#!/bin/sh
if [ "${1:-}" = version ]; then
  printf 'version: 0.2.16\ncommit: 18506d42c510e0cafe6acd748bcd8d83036cba40\n'
  exit 0
fi
exit 0
EOF
chmod 0755 "$current_home/cosmovisor/upgrades/v0.2.16/bin/decentralized-api"
ln -s upgrades/v0.2.16 "$current_home/cosmovisor/current"
current_output="$(cd "$temporary/work" && PATH="$temporary/bin:$PATH" GDC_JOIN_DAPI_UPGRADE_URL=https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip GDC_JOIN_DAPI_UPGRADE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GDC_JOIN_DAPI_EXPECTED_VERSION=0.2.16 GDC_JOIN_DAPI_EXPECTED_COMMIT=18506d42c510e0cafe6acd748bcd8d83036cba40 sh "$ENTRYPOINT" "$current_home")"
[[ "$current_output" == 'COSMOVISOR run' ]]
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" GDC_JOIN_DAPI_UPGRADE_URL=https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip GDC_JOIN_DAPI_UPGRADE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GDC_JOIN_DAPI_EXPECTED_VERSION=0.2.17 GDC_JOIN_DAPI_EXPECTED_COMMIT=18506d42c510e0cafe6acd748bcd8d83036cba40 sh "$ENTRYPOINT" "$current_home") >"$temporary/dapi-mismatch.out" 2>"$temporary/dapi-mismatch.err"; then
  echo 'stale Cosmovisor DAPI payload was accepted for a generated JOIN' >&2
  exit 1
fi
grep -Fq 'ERROR generated JOIN DAPI binary version does not match profile' "$temporary/dapi-mismatch.err"

broken_home="$temporary/broken"
mkdir -p "$broken_home/cosmovisor"
ln -s upgrades/missing "$broken_home/cosmovisor/current"
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$broken_home") \
  >"$temporary/broken.out" 2>"$temporary/broken.err"; then
  echo 'broken initialized DAPI home was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR initialized DAPI home has no runnable Cosmovisor current binary' \
  "$temporary/broken.err"
[[ ! -s "$temporary/broken.out" ]]

missing_current_home="$temporary/missing-current"
mkdir -p "$missing_current_home/cosmovisor/genesis/bin"
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$missing_current_home") \
  >"$temporary/missing-current.out" 2>"$temporary/missing-current.err"; then
  echo 'initialized DAPI home without a current link was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR initialized DAPI home has no runnable Cosmovisor current binary' \
  "$temporary/missing-current.err"
[[ ! -s "$temporary/missing-current.out" ]]

wrong_type_home="$temporary/wrong-type"
mkdir -p "$wrong_type_home/cosmovisor/upgrades/v0.2.16/bin/decentralized-api"
ln -s upgrades/v0.2.16 "$wrong_type_home/cosmovisor/current"
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$wrong_type_home") \
  >"$temporary/wrong-type.out" 2>"$temporary/wrong-type.err"; then
  echo 'DAPI home whose selected binary is a directory was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR initialized DAPI home has no runnable Cosmovisor current binary' \
  "$temporary/wrong-type.err"
[[ ! -s "$temporary/wrong-type.out" ]]

empty_cosmovisor_home="$temporary/empty-cosmovisor"
mkdir -p "$empty_cosmovisor_home/cosmovisor"
empty_output="$(cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$empty_cosmovisor_home")"
[[ "$empty_output" == INIT ]]

symlink_target="$temporary/symlink-target"
symlink_home="$temporary/symlink-home"
mkdir -p "$symlink_target/genesis/bin" "$symlink_home"
ln -s "$symlink_target" "$symlink_home/cosmovisor"
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$symlink_home") \
  >"$temporary/symlink.out" 2>"$temporary/symlink.err"; then
  echo 'symlinked initialized Cosmovisor home was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR initialized DAPI home has no runnable Cosmovisor current binary' \
  "$temporary/symlink.err"
[[ ! -s "$temporary/symlink.out" ]]

symlink_current_target="$temporary/symlink-current-target"
symlink_current_home="$temporary/symlink-current-home"
mkdir -p "$symlink_current_target/upgrades/v0.2.16/bin" "$symlink_current_home"
cat >"$symlink_current_target/upgrades/v0.2.16/bin/decentralized-api" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 0755 "$symlink_current_target/upgrades/v0.2.16/bin/decentralized-api"
ln -s upgrades/v0.2.16 "$symlink_current_target/current"
ln -s "$symlink_current_target" "$symlink_current_home/cosmovisor"
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$symlink_current_home") \
  >"$temporary/symlink-current.out" 2>"$temporary/symlink-current.err"; then
  echo 'symlinked initialized Cosmovisor home with valid current was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR initialized DAPI home has no runnable Cosmovisor current binary' \
  "$temporary/symlink-current.err"
[[ ! -s "$temporary/symlink-current.out" ]]

dangling_home="$temporary/dangling-home"
mkdir -p "$dangling_home"
ln -s "$temporary/missing-cosmovisor" "$dangling_home/cosmovisor"
if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" "$dangling_home") \
  >"$temporary/dangling.out" 2>"$temporary/dangling.err"; then
  echo 'dangling Cosmovisor home symlink was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR initialized DAPI home has no runnable Cosmovisor current binary' \
  "$temporary/dangling.err"
[[ ! -s "$temporary/dangling.out" ]]

if (cd "$temporary/work" && PATH="$temporary/bin:$PATH" sh "$ENTRYPOINT" relative) \
  >"$temporary/relative.out" 2>"$temporary/relative.err"; then
  echo 'relative DAPI home was accepted' >&2
  exit 1
fi
grep -Fq 'ERROR DAPI home must be an absolute path' "$temporary/relative.err"

printf 'PASS DAPI first start, initialized restart, and broken-state handling\n'
