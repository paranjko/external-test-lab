#!/bin/sh
# POSIX installer: verified download, same-filesystem atomic replacement,
# no elevated privileges and no edits to shell startup files.
set -eu

main() {
    version=${GONKACTL_VERSION:-1.0.0-alpha.5}
    version=${version#v}
    case "$version" in ''|*[!0-9A-Za-z.-]*) die 'Invalid GONKACTL_VERSION';; esac
    base="https://github.com/paranjko/external-test-lab/releases/download/gonkactl-v$version"
    base=${GONKACTL_RELEASE_BASE_URL:-$base}
    case "$base" in https://*) ;; *) die 'Release base URL must use HTTPS';; esac
    install_dir=${GONKACTL_INSTALL_DIR:-${HOME:?HOME is required}/.local/bin}
    case "$install_dir" in /*) ;; *) die 'GONKACTL_INSTALL_DIR must be absolute';; esac
    for tool in uname mktemp mkdir chmod mv rm awk sed cat; do need "$tool"; done
    if command -v curl >/dev/null 2>&1; then download_tool=curl
    elif command -v wget >/dev/null 2>&1; then download_tool=wget
    else die 'Install curl or wget first'; fi
    if command -v sha256sum >/dev/null 2>&1; then hash_tool=sha256sum
    elif command -v shasum >/dev/null 2>&1; then hash_tool=shasum
    else die 'Install sha256sum or shasum first'; fi
    case "$(uname -s)" in
        Linux) system=linux;;
        Darwin) system=darwin;;
        MINGW*|MSYS*) system=windows;;
        *) die 'Unsupported OS; see https://gonka-dev.net/ctl';;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64;;
        aarch64|arm64) arch=arm64;;
        *) die 'Unsupported CPU architecture';;
    esac
    binary=gonkactl
    extension=tar.gz
    if [ "$system" = windows ]; then
        binary=gonkactl.exe
        extension=zip
        need unzip
    else
        need tar
    fi
    archive="gonkactl_${version}_${system}_${arch}.$extension"
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/gonkactl-install.XXXXXXXX")
    staged=
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [ -t 1 ]; then say "Downloading gonkactl $version for $system/$arch"; fi
    download "$base/$archive" "$temporary/$archive"
    download "$base/checksums.txt" "$temporary/checksums.txt"
    expected=$(awk -v name="$archive" '$2 == name { count++; value=$1 } END { if (count != 1 || length(value) != 64 || value ~ /[^0-9a-f]/) exit 1; print value }' "$temporary/checksums.txt") || die 'Missing, duplicate or invalid SHA-256 entry'
    if [ "$hash_tool" = sha256sum ]; then
        actual=$(sha256sum "$temporary/$archive")
    else
        actual=$(shasum -a 256 "$temporary/$archive")
    fi
    actual=${actual%% *}
    [ "$actual" = "$expected" ] || die 'SHA-256 mismatch; installation aborted'
    # Extract just the expected binary to stdout. Archive paths and links are
    # never materialized, and unverified bytes never reach the install target.
    if [ "$extension" = zip ]; then
        unzip -p "$temporary/$archive" "$binary" > "$temporary/$binary"
    else
        tar -xzOf "$temporary/$archive" "$binary" > "$temporary/$binary"
    fi
    [ -s "$temporary/$binary" ] || die 'Archive has no executable'
    chmod 755 "$temporary/$binary"
    actual_version=$("$temporary/$binary" --version) || die 'Downloaded binary could not run'
    [ "$actual_version" = "$version" ] || die 'Downloaded binary reports an unexpected version'
    mkdir -p "$install_dir"
    [ ! -d "$install_dir/$binary" ] || die 'The destination is a directory'
    staged=$(mktemp "$install_dir/.gonkactl.XXXXXXXX")
    # cat is POSIX; check it before writing the destination staging file.
    need cat
    cat "$temporary/$binary" > "$staged"
    chmod 755 "$staged"
    mv -f "$staged" "$install_dir/$binary"
    staged=
    say "Installed $install_dir/$binary"
    case ":${PATH:-}:" in
        *":$install_dir:"*) ;;
        *)
            say 'Add the install directory to PATH in ~/.bashrc, ~/.zshrc or ~/.profile, then open a new shell:'
            # Single-quote paths safely, including spaces and apostrophes.
            quoted=$(printf '%s' "$install_dir" | sed "s/'/'\\\\''/g")
            printf "  export PATH='%s':\"\$PATH\"\n" "$quoted"
            ;;
    esac
    say 'Run gonkactl --help for the commands supported by your version. Host deployment operations are not available.'
}

need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
say() {
    if [ -t 1 ] && [ "${NO_COLOR+x}" != x ] && [ "${TERM:-dumb}" != dumb ]; then
        printf '\033[1;32m%s\033[0m\n' "$*"
    else printf '%s\n' "$*"; fi
}
die() { printf 'gonkactl installer: %s\n' "$*" >&2; exit 1; }
download() {
    if [ "$download_tool" = curl ]; then
        curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 300 --output "$2" "$1"
    else
        wget --https-only --timeout=30 --tries=3 --quiet --output-document="$2" "$1"
    fi
}
cleanup() {
    [ -z "${staged:-}" ] || rm -f "$staged"
    # This exact directory was created by mktemp in this invocation.
    [ -z "${temporary:-}" ] || rm -rf "$temporary"
}

main "$@"
