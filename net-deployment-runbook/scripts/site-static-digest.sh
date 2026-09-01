#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
[[ -d "$release_dir" ]] || { echo 'usage: site-static-digest.sh RELEASE_DIR' >&2; exit 2; }

(
  cd "$release_dir"
  find . -type f ! -name site-build.js -print0 | LC_ALL=C sort -z |
    xargs -0 sha256sum
) | sha256sum | awk '{print $1}'
