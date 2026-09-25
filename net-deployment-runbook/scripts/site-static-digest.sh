#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
[[ -d "$release_dir" ]] || { echo 'usage: site-static-digest.sh RELEASE_DIR' >&2; exit 2; }

(
  cd "$release_dir"
  # Receipts bind the trusted publisher and runtime. They are neither browser
  # assets nor part of the payload digest, and Caddy denies them explicitly.
  find . -type f \
    ! -name site-build.js \
    ! -name preview-composition.json \
    ! -name preview-legacy-composition.json \
    ! -name backend-build.json \
    ! -name preview-runtime-config.json \
    ! -name preview-changed-files.txt \
    ! -name frontend-build.json \
    ! -name backend-image.tar \
    ! -name backend-image.tar.sha256 \
    -print0 | LC_ALL=C sort -z |
    xargs -0 sha256sum
) | sha256sum | awk '{print $1}'
