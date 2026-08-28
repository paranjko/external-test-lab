#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

! grep -Fq 'command -v go' "$ROOT/scripts/verify-devshard-archive.sh"
! grep -Fq 'go version -m' "$ROOT/scripts/verify-devshard-archive.sh"

printf 'package main\nvar Version string\nfunc main() { println(Version) }\n' >"$tmp/main.go"
(
  cd "$tmp"
  GOCACHE="$tmp/go-cache" GO111MODULE=off CGO_ENABLED=0 go build \
    -ldflags='-X=main.Version=v4 -X=devshard/types.buildStateRootProtocolVersion=v4' \
    -o devshardd main.go
)
python3 -m zipfile -c "$tmp/source.zip" "$tmp/devshardd"
sha="$(sha256sum "$tmp/source.zip" | awk '{print $1}')"
url="file://$tmp/source.zip"

"$ROOT/scripts/verify-devshard-archive.sh" v4 "$url" "$sha" "$tmp/cache" >/dev/null
[[ "$(sha256sum "$tmp/cache/v4.zip" | awk '{print $1}')" == "$sha" ]]
jq -e --arg url "$url" --arg sha "$sha" \
  '.url == $url and .sha256 == $sha' "$tmp/cache/v4.source.json" >/dev/null

# Matching bytes from another source do not prove that the newly governed URL
# is retrievable. A changed URL must be fetched and may not reuse old bytes.
if "$ROOT/scripts/verify-devshard-archive.sh" v4 "file://$tmp/missing-source.zip" \
  "$sha" "$tmp/cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'cached bytes bypassed retrieval of a changed DevShard URL' >&2
  exit 1
fi
jq -e --arg url "$url" '.url == $url' "$tmp/cache/v4.source.json" >/dev/null

printf 'wrong\n' >"$tmp/wrong.zip"
wrong_url="file://$tmp/wrong.zip"
if "$ROOT/scripts/verify-devshard-archive.sh" v5 "$wrong_url" "$sha" "$tmp/cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'checksum mismatch was accepted' >&2
  exit 1
fi
grep -Fq 'archive checksum mismatch' "$tmp/err"
[[ ! -e "$tmp/cache/v5.zip" && ! -e "$tmp/cache/v5.zip.part" ]]

# A checksum-correct archive with another embedded protocol must fail closed.
if "$ROOT/scripts/verify-devshard-archive.sh" v5 "$url" "$sha" "$tmp/cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'mismatched executable protocol was accepted' >&2
  exit 1
fi
grep -Fq 'executable build metadata reports another protocol' "$tmp/err"

# Version metadata is token-bounded: v40 must not satisfy a v4 check merely
# because both required strings contain the shorter protocol as a prefix.
(
  cd "$tmp"
  GOCACHE="$tmp/go-cache" GO111MODULE=off CGO_ENABLED=0 go build \
    -ldflags='-X=main.Version=v40 -X=devshard/types.buildStateRootProtocolVersion=v40' \
    -o devshardd main.go
)
python3 -m zipfile -c "$tmp/v40.zip" "$tmp/devshardd"
v40_sha="$(sha256sum "$tmp/v40.zip" | awk '{print $1}')"
if "$ROOT/scripts/verify-devshard-archive.sh" v4 "file://$tmp/v40.zip" \
  "$v40_sha" "$tmp/v40-as-v4-cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'v40 executable metadata was accepted as v4' >&2
  exit 1
fi
grep -Fq 'executable build metadata reports another protocol' "$tmp/err"
"$ROOT/scripts/verify-devshard-archive.sh" v40 "file://$tmp/v40.zip" \
  "$v40_sha" "$tmp/v40-cache" >/dev/null

# Executable permissions and matching printable strings do not make an
# archive member a Linux/amd64 executable.
cat >"$tmp/devshardd" <<'EOF'
GOOS=linux
GOARCH=amd64
main.Version=v4
devshard/types.buildStateRootProtocolVersion=v4
EOF
chmod 0755 "$tmp/devshardd"
python3 -m zipfile -c "$tmp/not-elf.zip" "$tmp/devshardd"
not_elf_sha="$(sha256sum "$tmp/not-elf.zip" | awk '{print $1}')"
if "$ROOT/scripts/verify-devshard-archive.sh" v4 "file://$tmp/not-elf.zip" \
  "$not_elf_sha" "$tmp/not-elf-cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'non-ELF DevShard member was accepted' >&2
  exit 1
fi
grep -Fq 'not an ELF 64-bit little-endian x86-64 executable' "$tmp/err"

# A valid cached artifact must be reused even if the source disappears.
rm -f "$tmp/source.zip"
"$ROOT/scripts/verify-devshard-archive.sh" v4 "$url" "$sha" "$tmp/cache" >/dev/null

# A readable ZIP is not enough when its sole member is not an executable.
printf 'fixture\n' >"$tmp/devshardd"
chmod 0644 "$tmp/devshardd"
python3 -m zipfile -c "$tmp/not-executable.zip" "$tmp/devshardd"
not_executable_sha="$(sha256sum "$tmp/not-executable.zip" | awk '{print $1}')"
if "$ROOT/scripts/verify-devshard-archive.sh" v5 "file://$tmp/not-executable.zip" \
  "$not_executable_sha" "$tmp/not-executable-cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'non-executable DevShard member was accepted' >&2
  exit 1
fi
grep -Fq 'archive member is not a regular executable' "$tmp/err"

# Additional or nested archive members are rejected before extraction.
printf 'extra\n' >"$tmp/extra"
python3 -m zipfile -c "$tmp/extra-member.zip" "$tmp/devshardd" "$tmp/extra"
extra_sha="$(sha256sum "$tmp/extra-member.zip" | awk '{print $1}')"
if "$ROOT/scripts/verify-devshard-archive.sh" v4 "file://$tmp/extra-member.zip" \
  "$extra_sha" "$tmp/extra-cache" >"$tmp/out" 2>"$tmp/err"; then
  echo 'DevShard archive with extra members was accepted' >&2
  exit 1
fi
grep -Fq 'must contain exactly one root devshardd executable' "$tmp/err"

printf 'PASS DevShard archive verification\n'
