#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/../../.." && pwd -P)"
temporary="$(mktemp -d)"
runner_root="$(mktemp -d /tmp/gdc-runner-test.XXXXXX)"
rmdir "$runner_root"
trap 'rm -rf -- "$temporary" "$runner_root"' EXIT
assets="$temporary/assets"
mock_bin="$temporary/mock-bin"
install -d "$assets/runner/bin" "$assets/runner/externals" "$assets/shellcheck-v0.11.0" "$mock_bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$assets/runner/config.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$assets/runner/run.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$assets/runner/run-helper.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$assets/runner/bin/Runner.Listener"
printf 'fixture\n' >"$assets/runner/externals/fixture"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == --version ]]; then printf "version: 0.11.0\\n"; fi\n' >"$assets/shellcheck-v0.11.0/shellcheck"
chmod 0755 "$assets/runner/config.sh" "$assets/runner/run.sh" "$assets/runner/run-helper.sh" \
  "$assets/runner/bin/Runner.Listener" "$assets/shellcheck-v0.11.0/shellcheck"
tar -czf "$assets/runner.tar.gz" -C "$assets/runner" .
tar -cJf "$assets/shellcheck.tar.xz" -C "$assets" shellcheck-v0.11.0
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nfor ((i=1; i <= $#; i++)); do\n  if [[ "${!i}" == --output ]]; then next=$((i + 1)); destination="${!next}"; break; fi\ndone\n[[ "${destination:-}" ]]\ncase "$*" in *shellcheck*) cp "$GDC_TEST_SHELLCHECK_ARCHIVE" "$destination" ;; *) cp "$GDC_TEST_RUNNER_ARCHIVE" "$destination" ;; esac\n' >"$mock_bin/curl"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == is-active ]] && exit 1\nexit 0\n' >"$mock_bin/systemctl"
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nargs=()\nwhile (($#)); do\n  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac\ndone\nexec /usr/bin/install "${args[@]}"\n' >"$mock_bin/install"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/chown"
printf '#!/usr/bin/env bash\n# The disposable fixture proves scripts call the access check without granting a real Docker capability.\nexit 1\n' >"$mock_bin/runuser"
chmod 0755 "$mock_bin/curl" "$mock_bin/systemctl" "$mock_bin/install" "$mock_bin/chown" "$mock_bin/runuser"

cp -a "$root/ops/github-actions-runner" "$temporary/runner-assets"
runner_sha="$(sha256sum "$assets/runner.tar.gz" | awk '{print $1}')"
shellcheck_sha="$(sha256sum "$assets/shellcheck.tar.xz" | awk '{print $1}')"
sed -i "s/^RUNNER_SHA256=.*/RUNNER_SHA256=$runner_sha/; s/^SHELLCHECK_SHA256=.*/SHELLCHECK_SHA256=$shellcheck_sha/" \
  "$temporary/runner-assets/runner-manifest.env"

environment=(env "PATH=$mock_bin:$PATH" "GDC_RUNNER_TEST_MODE=1" "GDC_RUNNER_TEST_ROOT=$runner_root" \
  "GDC_TEST_RUNNER_ARCHIVE=$assets/runner.tar.gz" "GDC_TEST_SHELLCHECK_ARCHIVE=$assets/shellcheck.tar.xz")
"${environment[@]}" bash "$temporary/runner-assets/install.sh"
"${environment[@]}" bash "$temporary/runner-assets/install.sh"
test -x "$runner_root/config.sh"
test -x "$runner_root/shellcheck"
install -d "$runner_root/_work/job"
"${environment[@]}" bash "$temporary/runner-assets/cleanup.sh" --yes
"${environment[@]}" bash "$temporary/runner-assets/cleanup.sh" --yes
touch "$runner_root/.runner"
"${environment[@]}" bash "$temporary/runner-assets/update.sh"
"${environment[@]}" bash "$temporary/runner-assets/rollback.sh" --yes
rm -f "$runner_root/.runner"
"${environment[@]}" bash "$temporary/runner-assets/remove.sh" --yes
"${environment[@]}" bash "$temporary/runner-assets/remove.sh" --yes

if env -u GDC_RUNNER_TEST_MODE -u GDC_RUNNER_TEST_ROOT bash -c "source '$root/ops/github-actions-runner/lib.sh'; validate_target /"; then
  echo 'unsafe path fixture unexpectedly passed' >&2
  exit 1
fi
printf 'lifecycle and safety fixtures: PASS\n'
