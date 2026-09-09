#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
  echo "test-macos-portable-operator requires macOS" >&2
  exit 2
fi

brew_bin=$(command -v brew) || {
  echo "Homebrew is required to locate the supported Bash and jq" >&2
  exit 2
}
bash_bin=$("$brew_bin" --prefix bash)/bin/bash
jq_bin=$("$brew_bin" --prefix jq)/bin/jq

[ -x "$bash_bin" ] || {
  echo "Homebrew Bash is not executable: $bash_bin" >&2
  exit 2
}
[ -x "$jq_bin" ] || {
  echo "Homebrew jq is not executable: $jq_bin" >&2
  exit 2
}

"$bash_bin" -c '(( BASH_VERSINFO[0] >= 5 ))'
"$jq_bin" --version | grep -Eq '^jq-(1\.[6-9][0-9.]*|[2-9][0-9.]*)$'

if [ "${GDC_MACOS_PORTABLE_UNDER_BASH:-}" != "1" ]; then
  GDC_MACOS_PORTABLE_UNDER_BASH=1 \
    GDC_MACOS_BASH_BIN="$bash_bin" \
    GDC_MACOS_JQ_BIN="$jq_bin" \
    exec "$bash_bin" "$0"
fi

export PATH="${GDC_MACOS_BASH_BIN%/*}:${GDC_MACOS_JQ_BIN%/*}:/usr/bin:/bin:/usr/sbin:/sbin"

# Exercise the real backup/TMKMS validation under BSD-style base64 semantics.
# The production portable decoder must reject GNU `-d FILE` and fall back to
# BSD `-D -i FILE`; the shim also keeps legacy fixture commands readable.
base64_shim_dir=$(mktemp -d "${TMPDIR:-/tmp}/gdc-macos-base64.XXXXXX")
trap 'rm -rf "$base64_shim_dir"' EXIT HUP INT TERM
cat >"$base64_shim_dir/base64" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -d)
    shift
    if [ "$#" -eq 1 ]; then
      exec /usr/bin/base64 -D -i "$1"
    fi
    exec /usr/bin/base64 -D "$@"
    ;;
  *) exec /usr/bin/base64 "$@" ;;
esac
EOF
chmod 0755 "$base64_shim_dir/base64"
export PATH="$base64_shim_dir:$PATH"

for script in \
  gdc.sh \
  scripts/portable.sh \
  scripts/fetch-network-bootstrap.sh \
  scripts/network-bootstrap.sh \
  scripts/probe-public-peer.sh \
  scripts/join-profile.sh \
  scripts/resolve-join-profile.sh \
  scripts/record-join-result.sh \
  scripts/record-join-receipt.sh \
  scripts/verify-join-receipt-chain.sh \
  scripts/verify-join-resume-inputs.sh \
  scripts/ensure-inferenced-cli.sh \
  scripts/inferenced.sh \
  scripts/prepare-join-role-config.sh \
  scripts/detect-public-host.sh \
  scripts/resolve-join-components.sh; do
  /bin/sh -n "$script"
done

"$GDC_MACOS_BASH_BIN" -n \
  gdc-bash.sh \
  scripts/lib.sh \
  scripts/phase-join.sh \
  scripts/preflight-join-lineage.sh \
  scripts/gdc-report-github.sh \
  scripts/validator-backup.sh

for test_script in \
  scripts/test-gdc-bootstrap.sh \
  scripts/test-portable.sh \
  scripts/test-network-bootstrap-shell.sh \
  scripts/test-observe-network-state.sh \
  scripts/test-host-join-plan.sh \
  scripts/test-join-transition-receipts.sh \
  scripts/test-resolve-join-profile.sh \
  scripts/test-prepare-join-role-config.sh \
  scripts/test-explicit-public-host.sh \
  scripts/test-resolve-join-components.sh \
  scripts/test-ensure-inferenced-cli-output.sh \
  scripts/test-gdc-github-report.sh \
  scripts/test-validator-backup-contract.sh; do
  "$GDC_MACOS_BASH_BIN" "$test_script"
done
