#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATOR="$ROOT/scripts/generate-candidate-binary-sbom.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/archive"

cat >"$temporary/bin/syft" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source_path=
source_name=
output=
shift
while (($#)); do
  case "$1" in
    file:*) source_path="${1#file:}"; shift ;;
    --source-name) source_name="$2"; shift 2 ;;
    --output) output="${2#spdx-json=}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -f "$source_path" && -n "$source_name" && -n "$output" ]]
printf '%s\n' "$source_path" >>"$TEST_SYFT_SOURCES"
extra="${TEST_SYFT_EXTRA_FILE:-}"
jq -n --arg name "$source_name" --arg extra "$extra" '
  {name:$name,
   files:([{fileName:$name}] + (if $extra == "" then [] else [{fileName:$extra}] end)),
   packages:[{name:$name,primaryPackagePurpose:"FILE"}]}
' >"$output"
EOF
chmod +x "$temporary/bin/syft"

make_archive() {
  local archive="$1" member="$2"
  local staging="$temporary/archive/$member"
  mkdir -p "$staging"
  install -m 0755 /bin/true "$staging/$member"
  (cd "$staging" && zip -X -q "$archive" "$member")
}

make_archive "$temporary/decentralized-api.zip" decentralized-api
TEST_SYFT_SOURCES="$temporary/sources" PATH="$temporary/bin:$PATH" \
  "$GENERATOR" decentralized-api "$temporary/decentralized-api.zip" "$temporary/decentralized-api.spdx.json"
jq -e '.name == "decentralized-api" and [.files[].fileName] == ["decentralized-api"]' \
  "$temporary/decentralized-api.spdx.json" >/dev/null
grep -Eq '/decentralized-api$' "$temporary/sources"

make_archive "$temporary/inferenced-operator.zip" inferenced
TEST_SYFT_SOURCES="$temporary/sources" PATH="$temporary/bin:$PATH" \
  "$GENERATOR" inferenced-operator "$temporary/inferenced-operator.zip" "$temporary/inferenced-operator.spdx.json"
jq -e '.name == "inferenced" and [.files[].fileName] == ["inferenced"]' \
  "$temporary/inferenced-operator.spdx.json" >/dev/null

if TEST_SYFT_SOURCES="$temporary/sources" TEST_SYFT_EXTRA_FILE=libgcc_s.so.1 PATH="$temporary/bin:$PATH" \
  "$GENERATOR" decentralized-api "$temporary/decentralized-api.zip" "$temporary/invalid.spdx.json" 2>/dev/null; then
  echo 'candidate SBOM with an extra subject file was accepted' >&2
  exit 1
fi

cp "$temporary/decentralized-api.zip" "$temporary/extra-member.zip"
install -m 0644 /dev/null "$temporary/archive/companion"
zip -qj "$temporary/extra-member.zip" "$temporary/archive/companion"
if TEST_SYFT_SOURCES="$temporary/sources" PATH="$temporary/bin:$PATH" \
  "$GENERATOR" decentralized-api "$temporary/extra-member.zip" "$temporary/extra.spdx.json" 2>/dev/null; then
  echo 'candidate archive with an extra member was accepted for SBOM generation' >&2
  exit 1
fi

printf 'PASS candidate binary SBOM matches the published single-member payload\n'
