#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 || $# -eq 5 ]] || {
  echo 'usage: verify-candidate-binary-identity.sh COMPONENT EXECUTABLE VERSION COMMIT [metadata|operator]' >&2
  exit 2
}

component="$1"
executable="$2"
expected_version="$3"
expected_commit="$4"
mode="${5:-metadata}"

[[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] || {
  echo "candidate executable is not a regular executable: $executable" >&2
  exit 1
}
[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid candidate version: $expected_version" >&2
  exit 2
}
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "invalid candidate commit: $expected_commit" >&2
  exit 2
}

case "$component" in
  inferenced)
    expected_name=inference-chain
    expected_app=inferenced
    ;;
  decentralized-api)
    expected_name=decentralized-api
    expected_app=decentralized-api
    ;;
  *)
    echo "unsupported candidate identity component: $component" >&2
    exit 2
    ;;
esac
case "$mode" in
  metadata|operator) ;;
  *)
    echo "unsupported candidate identity verification mode: $mode" >&2
    exit 2
    ;;
esac
[[ "$mode" != operator || "$component" == inferenced ]] || {
  echo 'operator execution is supported only for inferenced' >&2
  exit 2
}

metadata="$(go version -m "$executable")"
for binding in \
  "-X github.com/cosmos/cosmos-sdk/version.Name=$expected_name" \
  "-X github.com/cosmos/cosmos-sdk/version.AppName=$expected_app" \
  "-X github.com/cosmos/cosmos-sdk/version.Version=$expected_version" \
  "-X github.com/cosmos/cosmos-sdk/version.Commit=$expected_commit"; do
  grep -Fq -- "$binding" <<<"$metadata" || {
    echo "candidate executable is missing reviewed build binding: $binding" >&2
    exit 1
  }
done

if [[ "$mode" == operator ]]; then
  ldd_output="$(mktemp)"
  trap 'rm -f "$ldd_output"' EXIT
  if ldd "$executable" >"$ldd_output" 2>&1; then
    echo 'candidate operator executable is dynamically linked' >&2
    cat "$ldd_output" >&2
    exit 1
  fi
  grep -Eq 'not a dynamic executable|statically linked' "$ldd_output" || {
    echo 'candidate operator static-link result is unrecognized' >&2
    cat "$ldd_output" >&2
    exit 1
  }

  version_output="$("$executable" version --long)"
  escaped_version="${expected_version//./\\.}"
  grep -Eq '^name: "?inference-chain"?$' <<<"$version_output"
  grep -Eq '^server_name: "?inferenced"?$' <<<"$version_output"
  grep -Eq "^version: \"?$escaped_version\"?$" <<<"$version_output"
  grep -Eq "^commit: \"?$expected_commit\"?$" <<<"$version_output"
fi

printf 'PASS candidate binary identity component=%s version=%s commit=%s mode=%s\n' \
  "$component" "$expected_version" "$expected_commit" "$mode"
