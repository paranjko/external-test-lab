#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
runner_dir="$(mktemp -d /tmp/gdc-runner-test.XXXXXX)"
download_dir="$(mktemp -d)"
trap 'rm -rf -- "$runner_dir" "$download_dir"' EXIT
# shellcheck source=../runner-manifest.env
source "$root/ops/github-actions-runner/runner-manifest.env"
archive="$download_dir/$SHELLCHECK_ARCHIVE"
curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$SHELLCHECK_URL"
printf '%s  %s\n' "$SHELLCHECK_SHA256" "$archive" | sha256sum --check --status
tar -xJf "$archive" -C "$download_dir"
install -d -m 0700 "$runner_dir"
install -m 0755 "$download_dir/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$runner_dir/shellcheck"

mapfile -t expected < <(find "$root/net-deployment-runbook" -type f -name '*.sh' -not -path "$root/net-deployment-runbook/vendor/*" -print | LC_ALL=C sort)
expected_count=${#expected[@]}
((expected_count > 0))
GDC_RUNNER_TEST_MODE=1 GDC_RUNNER_TEST_ROOT="$runner_dir" \
  "$root/ops/github-actions-runner/run-shellcheck-native.sh" "$root/net-deployment-runbook"
make -C "$root/net-deployment-runbook" shellcheck
actual_count="$(find "$root/net-deployment-runbook" -type f -name '*.sh' -not -path "$root/net-deployment-runbook/vendor/*" -print | LC_ALL=C sort | wc -l)"
[[ "$actual_count" == "$expected_count" ]]
printf 'native/Docker ShellCheck equivalence: PASS (%s scripts)\n' "$actual_count"
