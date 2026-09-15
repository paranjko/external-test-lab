#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source "$ROOT/scripts/profile.sh"

profile=v2026.09.13
url=https://github.com/gonka-ai/gonka/releases/download/devshard/v5.0.0/devshardd.zip
digest=ae2d1f90374b54efd4290b4df8b8c0ae339deb0d3b6e5b10936ea9f73155f564
GDC_RELEASE_PROFILE="$profile" load_profiles
[[ "$OFFICIAL_DEVSHARD_RELEASE" == true ]]
[[ "$DEVSHARD_SOURCE_REF" == devshard/v5.0.0 ]]
[[ "$DEVSHARD_COMMIT" == fae45d8c53180303b8345b56b2a9cc9dadcc0ffb ]]
[[ "$DEVSHARD_V5_URL" == "$url" && "$DEVSHARD_V5_SHA256" == "$digest" ]]
[[ "$DEVSHARD_RUNTIME_PACKAGING_PROFILE" == v2026.09.08-rc.0 ]]

comp="$tmp/official.json"
"$ROOT/gdc.sh" release composition create \
  --core v2026.08.06 --devshard "$profile" \
  --name official --output "$comp" >/dev/null
"$ROOT/gdc.sh" release composition verify "$comp" >/dev/null

# The deployment-facing selector must load the checked-in manifest by its
# filename-derived identifier before it rejects this deliberately invalid
# protocol list. This prevents a passing detached-manifest test from masking
# a composition-name mismatch in the real CLI path.
if GDC_HOME="$tmp/governance-home" "$ROOT/gdc.sh" \
  --composition core-v2026.08.06+devshard-v2026.09.13 \
  governance devshard submit --protocols v3,v3 >"$tmp/governance.out" 2>"$tmp/governance.err"; then
  echo 'official composition accepted duplicate DevShard protocols' >&2
  exit 1
fi
grep -Fq 'Duplicate DevShard protocol: v3' "$tmp/governance.err"
grep -Fq '"${OFFICIAL_DEVSHARD_RELEASE:-false}" == true' "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq "mutable_protocol=v5" "$ROOT/scripts/phase-governance-devshard.sh"

python3 - "$comp" "$url" "$digest" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
devshard = manifest["devshard"]
assert devshard["classification"] == "official-coreteam"
assert devshard["runtime_packaging_profile"] == "v2026.09.08-rc.0"
assert devshard["binaries"]["devshardd-linux-amd64"] == {"url": sys.argv[2], "sha256": sys.argv[3]}
assert "devshardd" not in devshard["images"]
assert "paranjko" in devshard["images"]["devshard-gateway"]
assert "paranjko" in devshard["images"]["devshard-host"]
PY

python3 - "$ROOT/scripts/release-candidate.py" "$ROOT/profiles/releases" "$tmp" <<'PY'
import importlib.util
from pathlib import Path
import shutil
import sys

spec = importlib.util.spec_from_file_location("release_candidate", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
release_dir = Path(sys.argv[2])
test_dir = Path(sys.argv[3]) / "releases"
test_dir.mkdir()
for name in ("v2026.09.13.lock", "v2026.09.08-rc.0.lock"):
    shutil.copyfile(release_dir / name, test_dir / name)
module.RELEASES = test_dir
original = (test_dir / "v2026.09.13.lock").read_text()
for old, new in (
    ("devshardd.zip", "other.zip"),
    ("ae2d1f90374b54efd4290b4df8b8c0ae339deb0d3b6e5b10936ea9f73155f564", "0" * 64),
    ("58049b91e5955f8159f490a14bbccb9a3a2632b3bf1a018a78f9fe188e0c4d98", "0" * 64),
):
    (test_dir / "v2026.09.13.lock").write_text(original.replace(old, new))
    try:
        module.load_profile_lock("v2026.09.13")
    except module.CandidateError:
        pass
    else:
        raise AssertionError(f"official lock accepted override of {old}")
PY

(
  unset DEVSHARD_V5_URL DEVSHARD_V5_SHA256
  GDC_COMPOSITION="$comp" load_profiles
  [[ "$OFFICIAL_DEVSHARD_RELEASE" == true ]]
  [[ "$DEVSHARD_V5_URL" == "$url" && "$DEVSHARD_V5_SHA256" == "$digest" ]]
  [[ "$(selected_gateway_protocol_contract)" == 'v3 v5' ]]
)

for variable in DEVSHARD_V5_URL DEVSHARD_V5_SHA256; do
  if (
    unset DEVSHARD_V5_URL DEVSHARD_V5_SHA256
    export "$variable=https://example.test/override"
    GDC_COMPOSITION="$comp" load_profiles
  ) >"$tmp/override.out" 2>"$tmp/override.err"; then
    echo "official profile accepted $variable override" >&2
    exit 1
  fi
  grep -Fq 'official DevShard v5.0.0 identity differs from the pinned Coreteam release' "$tmp/override.err"
done

printf 'PASS official DevShard v5.0.0 profile and composition\n'
