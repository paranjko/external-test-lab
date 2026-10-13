#!/bin/sh
# POSIX installer. No profile edits, elevated privileges, or unchecked execution.
set -eu

main() {
    trace_version=1.0.0-beta.1
    trace_quiet=0
    trace_preview=0
    for trace_arg in "$@"; do
        case "$trace_arg" in
            -q|--quiet) trace_quiet=1 ;;
            --dry-run) trace_preview=1 ;;
            -h|--help)
                # shellcheck disable=SC2016
                printf '%s\n' 'Install gonkactl-trace 1.0.0-beta.1' \
                    'Usage: sh install.sh [-q|--quiet] [--dry-run]' \
                    'GONKACTL_INSTALL_DIR overrides $HOME/.local/bin. Shell profiles are never modified.'
                return ;;
            *) fail "unknown option: $trace_arg" ;;
        esac
    done
    case "$(uname -s)" in
        Linux) trace_os=linux ;;
        Darwin) trace_os=darwin ;;
        MINGW*|MSYS*|CYGWIN*) trace_os=windows ;;
        *) fail 'unsupported OS; see https://gonka-dev.net/trace/' ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) trace_arch=amd64 ;;
        aarch64|arm64) trace_arch=arm64 ;;
        *) fail 'unsupported CPU architecture' ;;
    esac
    trace_binary=gonkactl-trace
    trace_extension=tar.gz
    if [ "$trace_os" = windows ]; then
        [ "$trace_arch" = amd64 ] || fail 'Windows releases support amd64 only'
        trace_binary=gonkactl-trace.exe
        trace_extension=zip
    fi
    trace_dir=${GONKACTL_INSTALL_DIR:-${HOME:?set HOME or GONKACTL_INSTALL_DIR}/.local/bin}
    case "$trace_dir" in /*) ;; *) fail 'GONKACTL_INSTALL_DIR must be an absolute path' ;; esac
    trace_asset="gonkactl-trace_${trace_version}_${trace_os}_${trace_arch}.${trace_extension}"
    trace_url="https://github.com/paranjko/external-test-lab/releases/download/gonkactl-trace-v${trace_version}"
    if [ "$trace_preview" = 1 ]; then
        printf 'Download: %s/%s\nVerify: %s/SHA256SUMS\nInstall: %s/%s\n' \
            "$trace_url" "$trace_asset" "$trace_url" "$trace_dir" "$trace_binary"
        return
    fi
    if command -v curl >/dev/null 2>&1; then trace_downloader=curl
    elif command -v wget >/dev/null 2>&1; then trace_downloader=wget
    else fail 'curl or wget is required'; fi
    if command -v sha256sum >/dev/null 2>&1; then trace_hash=sha256sum
    elif command -v shasum >/dev/null 2>&1; then trace_hash=shasum
    elif command -v openssl >/dev/null 2>&1; then trace_hash=openssl
    else fail 'SHA256 verification requires sha256sum, shasum or openssl'; fi
    if [ "$trace_extension" = zip ]; then
        command -v unzip >/dev/null 2>&1 || fail 'unzip is required'
    else
        command -v tar >/dev/null 2>&1 || fail 'tar is required'
    fi
    umask 077
    trace_tmp=$(mktemp -d "${TMPDIR:-/tmp}/gonkactl-trace.XXXXXXXX")
    trace_stage=
    trap 'cleanup' 0
    trap 'exit 1' HUP INT TERM
    say "Downloading gonkactl-trace $trace_version ($trace_os/$trace_arch)"
    download "$trace_url/$trace_asset" "$trace_tmp/archive"
    download "$trace_url/SHA256SUMS" "$trace_tmp/SHA256SUMS"
    trace_expected=
    while read -r trace_sum trace_name trace_extra; do
        if [ "$trace_name" = "$trace_asset" ]; then
            if [ -n "$trace_expected" ] || [ -n "$trace_extra" ]; then fail 'ambiguous checksum entry'; fi
            trace_expected=$trace_sum
        fi
    done < "$trace_tmp/SHA256SUMS"
    [ "${#trace_expected}" = 64 ] || fail 'missing or invalid SHA256 entry'
    case "$trace_expected" in *[!0-9a-f]*) fail 'invalid SHA256 entry' ;; esac
    case "$trace_hash" in
        sha256sum) trace_actual=$(sha256sum "$trace_tmp/archive"); trace_actual=${trace_actual%% *} ;;
        shasum) trace_actual=$(shasum -a 256 "$trace_tmp/archive"); trace_actual=${trace_actual%% *} ;;
        openssl) trace_actual=$(openssl dgst -sha256 "$trace_tmp/archive"); trace_actual=${trace_actual##* } ;;
    esac
    [ "$trace_expected" = "$trace_actual" ] || fail 'SHA256 mismatch; nothing installed'
    # Extract only the expected member to a file we control, never archive paths.
    if [ "$trace_extension" = zip ]; then
        unzip -p "$trace_tmp/archive" "$trace_binary" > "$trace_tmp/binary"
    else
        tar -xzOf "$trace_tmp/archive" "$trace_binary" > "$trace_tmp/binary"
    fi
    [ -s "$trace_tmp/binary" ] || fail 'archive has no binary'
    mkdir -p "$trace_dir"
    [ ! -L "$trace_dir/$trace_binary" ] || fail 'refusing to replace a symlink'
    [ ! -d "$trace_dir/$trace_binary" ] || fail 'installation target is a directory'
    trace_stage=$(mktemp "$trace_dir/.gonkactl-trace.XXXXXXXX")
    cat "$trace_tmp/binary" > "$trace_stage"
    chmod 755 "$trace_stage"
    mv -f "$trace_stage" "$trace_dir/$trace_binary"
    trace_stage=
    say "Installed $trace_dir/$trace_binary"
    case ":${PATH:-}:" in
        *":$trace_dir:"*) ;;
        *)
            if [ "$trace_quiet" = 0 ]; then
                trace_quoted=$(printf '%s' "$trace_dir" | sed "s/'/'\\\\''/g")
                # shellcheck disable=SC2016
                printf 'Add to ~/.bashrc, ~/.zshrc or ~/.profile, then open a new shell:\n  export PATH='"'"'%s'"'"':"$PATH"\n' "$trace_quoted"
            fi ;;
    esac
}

fail() { printf 'gonkactl-trace: %s\n' "$*" >&2; exit 1; }
say() { if [ "$trace_quiet" = 0 ]; then printf '%s\n' "$*"; fi; }
download() {
    if [ "$trace_downloader" = curl ]; then
        curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fLsS --connect-timeout 15 --max-time 300 "$1" -o "$2"
    else
        wget -q --https-only --timeout=30 -O "$2" "$1"
    fi
}
cleanup() {
    if [ -n "$trace_stage" ]; then rm -f "$trace_stage"; fi
    if [ -n "$trace_tmp" ]; then rm -rf "$trace_tmp"; fi
}

# A function keeps a truncated curl | sh download from installing anything.
main "$@"
