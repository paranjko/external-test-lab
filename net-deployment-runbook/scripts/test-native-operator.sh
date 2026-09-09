#!/usr/bin/env bash
# Opt-in network test. Uses an official historical release and disposable keys;
# it does not observe the live network, call SSH, or perform a JOIN.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'this test requires a real macOS workstation' >&2; exit 2; }
source "$ROOT/scripts/operator-platform.sh"
platform="$(operator_platform)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
umask 077
mkdir "$tmp/guard"
for tool in docker ssh; do
  cat >"$tmp/guard/$tool" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected local Docker or SSH invocation\n' >&2
exit 99
EOF
  chmod 700 "$tmp/guard/$tool"
done
export PATH="$tmp/guard:$PATH"
export GDC_HOME="$tmp/data"
"$ROOT/gdc.sh" --help >"$tmp/help"
grep -Fq 'Gonka DevNet Community manual deployment' "$tmp/help"
GDC_TEST_PROFILE_OUTPUT="$tmp/profile.json" "$ROOT/scripts/test-join-profile.sh" >"$tmp/fixture.log"
# The fixture Core release is intentionally fixed. No fallback to latest.
version="$(jq -r .spec.components.core.observed.version "$tmp/profile.json")"
commit="$(jq -r .spec.components.core.observed.commit "$tmp/profile.json")"
tag="release/v$version"
curl -fsSL --connect-timeout 15 --max-time 60 "https://api.github.com/repos/gonka-ai/gonka/releases/tags/${tag//\//%2F}" >"$tmp/release.json"
curl -fsSL --connect-timeout 15 --max-time 60 "https://api.github.com/repos/gonka-ai/gonka/git/matching-refs/tags/$tag" >"$tmp/refs.json"
jq -e --arg tag "$tag" --arg commit "$commit" '[.[] | select(.ref == ("refs/tags/" + $tag) and .object.type == "commit" and .object.sha == $commit)] | length == 1' "$tmp/refs.json" >/dev/null
jq -e --arg tag "$tag" --arg asset "inferenced-$platform.zip" '.tag_name == $tag and ([.assets[] | select(.name == $asset and (.digest | test("^sha256:[a-f0-9]{64}$")))] | length == 1)' "$tmp/release.json" >/dev/null
jq --arg p "$platform" --arg tag "$tag" --slurpfile release "$tmp/release.json" '
  ($release[0].assets[] | select(.name == ("inferenced-" + $p + ".zip"))) as $asset |
  .spec.components.operator_cli = {
    platform:$p,expected_runtime:.spec.components.core.expected_runtime,
    binary:{url:$asset.browser_download_url,sha256:($asset.digest | ltrimstr("sha256:"))},
    source:{component:"operator",provider:"github",repository:"gonka-ai/gonka",tag_authority_repository:"gonka-ai/gonka",release_tag:$tag,commit:.spec.components.core.observed.commit,
      asset:($asset | {name,browser_download_url,digest})}}
' "$tmp/profile.json" >"$tmp/with-operator.json"
id="$(jq -cS .spec "$tmp/with-operator.json" | sha256sum | awk '{print $1}')"
jq --arg id "$id" '.profile_id=$id' "$tmp/with-operator.json" >"$tmp/profile.json"
"$ROOT/scripts/ensure-inferenced-cli.sh" --join-profile "$tmp/profile.json"
binary="$GDC_HOME/bin/$id/inferenced"
"$binary" version | grep -Fq "$version"
# Random disposable key. Capture generated recovery material; never print it.
"$binary" keys add native-test --home "$tmp/keyring" --keyring-backend test --output json >"$tmp/key.json" 2>"$tmp/key.err"
address="$("$binary" keys show native-test --home "$tmp/keyring" --keyring-backend test -a)"
jq -e --arg a "$address" '.address == $a' "$tmp/key.json" >/dev/null
jq -er .mnemonic "$tmp/key.json" >"$tmp/mnemonic"
printf 'native-test-password\n' >"$tmp/password"
GDC_RECOVERY_INFERENCED_BIN="$binary" "$ROOT/scripts/derive-mnemonic-identity.sh" "$tmp/mnemonic" "$tmp/password" native-test "$address" >"$tmp/recovered.json"
jq -e --arg a "$address" '.address == $a' "$tmp/recovered.json" >/dev/null
printf 'PASS native platform=%s release=%s archive_sha256=%s; launcher, Darwin CLI, test keyring and file-keyring recovery; no JOIN performed\n' \
  "$platform" "$version" "$(jq -r .spec.components.operator_cli.binary.sha256 "$tmp/profile.json")"
