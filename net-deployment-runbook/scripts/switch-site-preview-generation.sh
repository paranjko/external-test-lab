#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
preview_number="${2:-}"
generation="${3:-}"
preview_root="${GDC_SITE_PREVIEW_ROOT:-/srv/dai/edge/site/preview}"

[[ "$preview_number" =~ ^[1-9][0-9]*$ ]] || {
  echo 'preview number must be a positive integer' >&2
  exit 2
}
[[ "$preview_root" = /* && "$preview_root" != / ]] || {
  echo 'preview root must be an absolute non-root directory' >&2
  exit 2
}

generation_root="$preview_root/.generations/$preview_number"
active="$preview_root/$preview_number"

validate_target() {
  local target="$1"
  [[ -z "$target" || "$target" =~ ^\.generations/$preview_number/[0-9a-f]{40}$ ]] || {
    echo 'preview pointer has an unsafe target' >&2
    exit 1
  }
}

case "$action" in
  publish)
    [[ "$generation" =~ ^[0-9a-f]{40}$ ]] || {
      echo 'preview generation must be a full revision' >&2
      exit 2
    }
    staging="$generation_root/.staging-$generation"
    release="$generation_root/$generation"
    [[ -d "$staging" && ! -e "$release" ]] || {
      echo 'preview generation is missing or already published' >&2
      exit 1
    }
    test -s "$staging/index.html"
    test -s "$staging/app.js"
    test -s "$staging/site-build.js"
    test -s "$staging/preview-composition.json"
    grep -Fq 'src="/config.js"' "$staging/index.html"
    grep -Fq '"config": "/config.js"' "$staging/preview-composition.json"
    mode="$(sed -n 's/.*"mode": "\(static\|endpoint\|combined\)".*/\1/p' "$staging/preview-composition.json")"
    [[ -n "$mode" ]] || { echo 'preview composition mode is invalid' >&2; exit 1; }
    if [[ "$mode" == endpoint || "$mode" == combined ]]; then
      grep -Fq '"/preview/<PR>/status/*"' "$staging/preview-composition.json"
      grep -Fq '"/preview/<PR>/status/gateway/v1/admission-status"' "$staging/preview-composition.json"
      grep -Eq '"sha256": "[0-9a-f]{64}"' "$staging/preview-composition.json"
    fi
    expected="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$staging/site-build.js")"
    actual="$(
      cd "$staging"
      find . -type f \
        ! -name site-build.js \
        ! -name preview-composition.json \
        ! -name preview-legacy-composition.json \
        ! -name backend-build.json \
        ! -name preview-runtime-config.json \
        ! -name preview-changed-files.txt \
        ! -name frontend-build.json \
        -print0 | LC_ALL=C sort -z |
        xargs -0 sha256sum | sha256sum | awk '{print $1}'
    )"
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$expected" == "$actual" ]] || {
      echo 'preview staged payload digest is invalid' >&2
      exit 1
    }
    for synthetic_endpoint in status/participants status/software status/gpus; do
      [[ ! -e "$staging/$synthetic_endpoint" ]] || {
        echo "preview staged payload contains synthetic endpoint: $synthetic_endpoint" >&2
        exit 1
      }
    done
    previous="$(readlink "$active" 2>/dev/null || true)"
    validate_target "$previous"
    printf '%s\n' "$previous" >"$staging/previous-generation"
    mv -T "$staging" "$release"
    ln -s ".generations/$preview_number/$generation" "$preview_root/.next-$preview_number"
    mv -Tf "$preview_root/.next-$preview_number" "$active"
    [[ "$(readlink "$active")" == ".generations/$preview_number/$generation" ]]
    ;;
  rollback)
    current="$(readlink "$active")"
    validate_target "$current"
    [[ -n "$current" ]] || { echo 'preview has no active generation' >&2; exit 1; }
    previous="$(cat "$active/previous-generation")"
    validate_target "$previous"
    [[ -n "$previous" && -d "$preview_root/$previous" ]] || {
      echo 'preview has no retained previous generation' >&2
      exit 1
    }
    ln -s "$previous" "$preview_root/.rollback-$preview_number"
    mv -Tf "$preview_root/.rollback-$preview_number" "$active"
    [[ "$(readlink "$active")" == "$previous" ]]
    ;;
  *)
    echo 'usage: switch-site-preview-generation.sh publish <PR> <revision> | rollback <PR>' >&2
    exit 2
    ;;
esac
