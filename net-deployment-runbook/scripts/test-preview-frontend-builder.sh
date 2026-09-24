#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
builder="$root/ops/preview/build-frontend-artifact.sh"
dockerfile="$root/ops/preview/Dockerfile.frontend-builder"

for file in "$builder" "$dockerfile"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "missing trusted frontend builder file: $file" >&2; exit 1; }
done
bash -n "$builder"
grep -Eq '^FROM node:[0-9]+-slim@sha256:[0-9a-f]{64}$' "$dockerfile"
grep -Fq 'USER node' "$dockerfile"
grep -Fq 'git jq make rsync' "$dockerfile"
grep -Fq -- 'git -C "$source_repository" archive --format=tar "$revision"' "$builder"
grep -Fq -- 'build_uid="$(id -u)"' "$builder"
grep -Fq -- 'build_gid="$(id -g)"' "$builder"
grep -Fq -- '--read-only --user "$build_uid:$build_gid" --cap-drop ALL' "$builder"
grep -Fq -- '--security-opt no-new-privileges --pids-limit 256 --memory 1g --cpus 1' "$builder"
grep -Fq -- '-v "$source_dir:/input:ro" -v "$stage:/out"' "$builder"
grep -Fq 'frontend build for this output is already running or retained for diagnosis' "$builder"
grep -Fq 'failure_log="${output}.failed.log"' "$builder"
grep -Fq 'terminal log retained at $failure_log' "$builder"
if rg -n -- '-v [^[:space:]]*(GDC_HOME|docker\.sock|\.ssh)|/var/run/docker\.sock|/root/\.ssh' "$builder" "$dockerfile"; then
  echo 'frontend builder must not mount or read operator credentials or Docker control sockets' >&2
  exit 1
fi

printf 'PASS frontend builder static isolation contract\n'
