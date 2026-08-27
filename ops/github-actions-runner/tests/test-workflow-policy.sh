#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
checker="$root/ops/github-actions-runner/check-workflow-policy.py"
workflows="$root/.github/workflows"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

cp -a "$workflows" "$temporary/workflows"
python3 "$checker" "$temporary/workflows"

cp -a "$workflows" "$temporary/non-versioned"
sed -i 's|actions/checkout@v[0-9.]\+|actions/checkout@latest|' "$temporary/non-versioned/net-deployment-runbook.yml"
if python3 "$checker" "$temporary/non-versioned" >"$temporary/non-versioned.out" 2>&1; then
  echo 'non-versioned action fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'non-versioned action' "$temporary/non-versioned.out"

cp -a "$workflows" "$temporary/publication"
sed -i '0,/runs-on: ubuntu-latest/s//runs-on: [self-hosted, linux, x64, gdc-node4]/' "$temporary/publication/candidate-publish.yml"
if python3 "$checker" "$temporary/publication" >"$temporary/publication.out" 2>&1; then
  echo 'candidate publication routing fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'candidate publication must remain hosted' "$temporary/publication.out"

cp -a "$workflows" "$temporary/pr-route"
sed -i "s/github.event_name != 'pull_request'/true/" "$temporary/pr-route/net-deployment-runbook.yml"
if python3 "$checker" "$temporary/pr-route" >"$temporary/pr-route.out" 2>&1; then
  echo 'pull-request routing fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'does not exclude pull requests' "$temporary/pr-route.out"

cp -a "$workflows" "$temporary/unprotected-ref"
sed -i "s/github.ref == format('refs\/heads\/{0}', github.event.repository.default_branch)/true/" "$temporary/unprotected-ref/net-deployment-runbook.yml"
if python3 "$checker" "$temporary/unprotected-ref" >"$temporary/unprotected-ref.out" 2>&1; then
  echo 'unprotected ref fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'default-branch constrained' "$temporary/unprotected-ref.out"

cp -a "$workflows" "$temporary/generic-label"
sed -i 's/"gdc-node4"/"generic"/' "$temporary/generic-label/candidate-build.yml"
if python3 "$checker" "$temporary/generic-label" >"$temporary/generic-label.out" 2>&1; then
  echo 'generic label fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'all four dedicated labels' "$temporary/generic-label.out"

cp -a "$workflows" "$temporary/write-permission"
sed -i 's/contents: read/contents: write/' "$temporary/write-permission/net-deployment-runbook.yml"
if python3 "$checker" "$temporary/write-permission" >"$temporary/write-permission.out" 2>&1; then
  echo 'write permission fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'not read-only' "$temporary/write-permission.out"

cp -a "$workflows" "$temporary/secret"
printf '\n      - run: echo "${{ secrets.TEST }}"\n' >>"$temporary/secret/candidate-build.yml"
if python3 "$checker" "$temporary/secret" >"$temporary/secret.out" 2>&1; then
  echo 'secret fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'references secrets' "$temporary/secret.out"

cp -a "$workflows" "$temporary/docker"
printf '\n      - run: docker version\n' >>"$temporary/docker/candidate-build.yml"
if python3 "$checker" "$temporary/docker" >"$temporary/docker.out" 2>&1; then
  echo 'Docker fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'mentions Docker' "$temporary/docker.out"

cp -a "$workflows" "$temporary/environment"
sed -i "s/'gdc-node4-runner'/'missing-environment'/" "$temporary/environment/net-deployment-runbook.yml"
if python3 "$checker" "$temporary/environment" >"$temporary/environment.out" 2>&1; then
  echo 'missing environment fixture unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'environment is missing' "$temporary/environment.out"

printf 'workflow policy fixtures: PASS\n'
