#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
  echo "Usage: $0 staged-bootstrap-directory published-bootstrap-directory" >&2
  exit 2
}

source_dir="$1"
published_dir="$2"
published_parent="$(dirname "$published_dir")"
mkdir -p "$published_parent"
bootstrap_stage="$(mktemp -d "$published_parent/.join-bootstrap.XXXXXX")"
trap 'rm -rf -- "$bootstrap_stage"' EXIT
chmod 0755 "$bootstrap_stage"

if [[ -d "$source_dir" ]]; then
  [[ -s "$source_dir/manifest.sha256" ]] || {
    echo 'staged public JOIN bootstrap has no manifest' >&2
    exit 1
  }
  (cd "$source_dir" && sha256sum -c manifest.sha256 >/dev/null) || {
    echo 'staged public JOIN bootstrap does not match its manifest' >&2
    exit 1
  }
  cp -a "$source_dir/." "$bootstrap_stage/"
fi

# A participant-edge refresh has no bundle of its own. It must retain the
# verified bundle already owned by the public edge rather than publishing an
# empty directory. A staged manifest is the sole authority to replace it.
if [[ -s "$bootstrap_stage/manifest.sha256" ]]; then
  if [[ -s "$published_dir/manifest.sha256" ]] \
    && cmp -s "$bootstrap_stage/manifest.sha256" "$published_dir/manifest.sha256"; then
    :
  else
    rm -rf -- "$published_dir" "$published_dir.current"
    mv "$bootstrap_stage" "$published_dir"
    bootstrap_stage=''
  fi
fi

[[ ! -d "$published_dir" ]] || chmod -R a+rX "$published_dir"
