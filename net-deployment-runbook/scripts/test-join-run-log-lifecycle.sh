#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF
mkdir -p "$tmp/bin"
python3 - "$tmp" <<'PY'
import os
import sys
import zipfile

root = sys.argv[1]
binary = os.path.join(root, "inferenced")
with open(binary, "w", encoding="utf-8") as handle:
    handle.write("#!/usr/bin/env bash\nprintf 'inferenced v0.2.15\\n'\n")
os.chmod(binary, 0o755)
with zipfile.ZipFile(os.path.join(root, "inferenced-fixture.zip"), "w") as archive:
    archive.write(binary, "inferenced")
PY
FIXTURE_INFERENCED_ARCHIVE="$tmp/inferenced-fixture.zip"
FIXTURE_INFERENCED_SHA256="$(sha256sum "$FIXTURE_INFERENCED_ARCHIVE" | awk '{print $1}')"
export FIXTURE_INFERENCED_ARCHIVE FIXTURE_INFERENCED_SHA256
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mode="${BLOCKLIST_CURL_MODE:-bootstrap_failure}"
url=''
output=''
headers=''
for ((index = 1; index <= $#; index++)); do
  [[ "${!index}" == http* ]] && url="${!index}"
  [[ "${!index}" == -o ]] || continue
  next=$((index + 1))
  output="${!next}"
done
for ((index = 1; index <= $#; index++)); do
  [[ "${!index}" == -D ]] || continue
  next=$((index + 1))
  headers="${!next}"
  break
done
[[ "$mode" == component_failure || "$mode" == profile_failure ]] || exit 2
case "$url" in
  *'/releases/tags/release%2Fv0.2.15')
    printf '{"tag_name":"release/v0.2.15","assets":[{"name":"inferenced-linux-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-linux-amd64.zip","digest":"sha256:%s"}]}\n' "$FIXTURE_INFERENCED_SHA256"
    exit 0
    ;;
  *'/git/matching-refs/tags/release/v0.2.15')
    printf '%s\n' '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]'
    exit 0
    ;;
  *'/releases/tags/release%2Fv0.2.16')
    [[ "$mode" == component_failure ]] && exit 22
    printf '%s\n' '{"tag_name":"release/v0.2.16","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}'
    exit 0
    ;;
  *'/git/matching-refs/tags/release/v0.2.16')
    printf '%s\n' '[{"ref":"refs/tags/release/v0.2.16","object":{"type":"commit","sha":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}]'
    exit 0
    ;;
  *'ghcr.io/token?'*)
    printf '%s\n' '{"token":"fixture-token"}'
    exit 0
    ;;
  *'ghcr.io/v2/'*'/manifests/'*)
    [[ -n "$headers" ]] || exit 2
    printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\r\n' >"$headers"
    exit 0
    ;;
  *raw.githubusercontent.com/gonka-ai/gonka/*/deploy/join/docker-compose.yml)
    printf '%s\n' $'services:\n  node:\n    image: ghcr.io/product-science/inferenced:0.2.15\n  api:\n    image: ghcr.io/product-science/api:0.2.15-post3'
    exit 0
    ;;
  *inferenced-linux-amd64.zip*)
    [[ "${INFERENCED_CURL_MODE:-available}" == available ]] || exit 2
    [[ -n "$output" ]] || exit 2
    cp "$FIXTURE_INFERENCED_ARCHIVE" "$output"
    exit 0
    ;;
  *node0.example.test*) id=0123456789abcdef0123456789abcdef01234567; remote_ip=8.8.4.1 ;;
  *node1.example.test*) id=89abcdef0123456789abcdef0123456789abcdef; remote_ip=8.8.4.2 ;;
  *) exit 2 ;;
esac
case "$url" in
  */status)
    printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community","version":"0.2.15"},"sync_info":{"catching_up":false}}}\n' "$id"
    ;;
  */abci_info) printf '%s\n' '{"result":{"response":{"version":"0.2.15"}}}' ;;
  */net_info) printf '%s\n' '{"result":{"peers":[]}}' ;;
  */v1/versions)
    printf '%s\n' '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.16","commit":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}'
    ;;
  *) exit 2 ;;
esac
for arg in "$@"; do
  if [[ "$arg" == --write-out ]]; then
    printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
  fi
done
EOF
chmod 0755 "$tmp/bin/curl"
cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == *host-stack-compose.yml ]]; then
  printf '%s  %s\n' d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 "$1"
else
  /usr/bin/sha256sum "$@"
fi
EOF
chmod 0755 "$tmp/bin/sha256sum"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${!#}" == 'sudo -n bash -s' ]]; then
  cat >/dev/null
  [[ "${READINESS_MODE:-fail}" == ok ]] || exit 1
  printf 'READY Host readiness preflight\n'
  printf 'Authorization: Bearer fixture-run-log-secret\n'
  exit 0
fi
if [[ "${!#}" == 'bash -s' ]]; then
  cat >/dev/null
  if [[ "${ACCELERATOR_MODE:-supported}" == unsupported_profile ]]; then
    cat <<'INSPECTION'
vendor=amd
pci_device_id=0x7550
os_id=ubuntu
os_version_id=26.04
kernel_release=7.0.0-31-generic
amdrocm_status=install ok installed
amdrocm_version=7.14.0~pre3-29052710811
rocm_core_status=absent
rocm_core_version=absent
amdgpu_install_status=install ok installed
amdgpu_install_version=31.40.1.26130000-2383377.26.04
readiness=ready
architecture=gfx9999
render_node=renderD129
kfd_group_id=44
render_group_id=109
INSPECTION
    exit 0
  fi
  printf 'vendor=nvidia\n'
  exit 0
fi
echo "unexpected fixture SSH invocation: $*" >&2
exit 1
EOF
chmod 0755 "$tmp/bin/ssh"

latest_failure() { cat "$1/reporting/failures/latest-failure"; }

# Scenario A: the Host readiness preflight fails after run allocation. The run
# log must exist, be bounded to the allocated run directory, and carry both
# lifecycle markers plus the preflight status output.
rc=0
if GDC_JOIN_PREFLIGHT_DEADLINE=5 PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator" \
  "$ROOT/gdc.sh" host join --bootstrap-file "$tmp/bootstrap.json" \
  --public-host validator-a.example.test validator-a >"$tmp/a.out" 2>"$tmp/a.err"; then
  echo 'a failing Host readiness preflight unexpectedly succeeded' >&2
  exit 1
fi
rc="$(sed -n 's/^exit_code=//p' "$tmp/operator/reporting/invocations/invocation.$(latest_failure "$tmp/operator")/failure.env" | tail -n1)"
[[ "$rc" == 1 ]]
awk 'index($0, "ERROR JOIN preflight failed checkpoint=host-readiness") { found=1 } END { exit !found }' "$tmp/a.err"
awk '$0 == "END host join FAILED exit=1" { found=1 } END { exit !found }' "$tmp/a.err"
failure="$tmp/operator/reporting/invocations/invocation.$(latest_failure "$tmp/operator")/failure.env"
run_log="$(awk -F= '$1 == "run_log" { print $2 }' "$failure")"
[[ -f "$run_log" && ! -L "$run_log" ]]
[[ "$(stat -c %a "$run_log")" == 600 ]]
awk 'BEGIN { ok=0 } $0 ~ /^BEGIN phase=join-preflight timestamp=[0-9TZ:-]+ run_id=[0-9TZ-]+-[0-9]+$/ { ok=1 } END { exit !ok }' "$run_log"
awk -v rc="$rc" '$0 ~ "^END phase=join-preflight status=" rc " timestamp=[0-9TZ:-]+$" { ok=1 } END { exit !ok }' "$run_log"
awk 'index($0, "ERROR JOIN preflight failed checkpoint=host-readiness") { found=1 } END { exit !found }' "$run_log"
[[ "$(find "$tmp/operator" -type f -name run.log | wc -l)" == 1 ]]
awk -F= -v expected_path="$run_log" '$1 == "run_log" && $2 == expected_path { found=1 } END { exit !found }' "$failure"

# Scenario B: fetch the Bootstrap document through the ordinary production
# path. A transport failure after readiness must still bind one local run log
# to the reportable failure; it must not report run_log=unavailable.
if READINESS_MODE=ok GDC_JOIN_PREFLIGHT_DEADLINE=5 \
  PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator-bootstrap" "$ROOT/gdc.sh" host join \
  --public-host validator-bootstrap.example.test validator-bootstrap \
  >"$tmp/bootstrap.out" 2>"$tmp/bootstrap.err"; then
  echo 'a failing Bootstrap fetch unexpectedly succeeded' >&2
  exit 1
fi
awk 'index($0, "checkpoint=bootstrap-fetch") { found=1 } END { exit !found }' "$tmp/bootstrap.err"
bootstrap_failure="$tmp/operator-bootstrap/reporting/invocations/invocation.$(latest_failure "$tmp/operator-bootstrap")/failure.env"
bootstrap_log="$(awk -F= '$1 == "run_log" { print $2 }' "$bootstrap_failure")"
[[ -f "$bootstrap_log" && ! -L "$bootstrap_log" ]]
[[ "$(stat -c %a "$bootstrap_log")" == 600 ]]
awk 'index($0, "checkpoint=bootstrap-fetch") { found=1 } END { exit !found }' "$bootstrap_log"
awk '$0 ~ /^END phase=join-preflight status=[1-9][0-9]* timestamp=/ { found=1 } END { exit !found }' "$bootstrap_log"
[[ "$(find "$tmp/operator-bootstrap" -type f -name run.log | wc -l)" == 1 ]]

# Scenario C: readiness passes and a later software-observation checkpoint
# fails. The same single log keeps accumulating; no second run log is created.
if BLOCKLIST_CURL_MODE=bootstrap_failure READINESS_MODE=ok GDC_JOIN_PREFLIGHT_DEADLINE=5 \
  PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator-b" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --public-host validator-b.example.test validator-b \
  >"$tmp/b.out" 2>"$tmp/b.err"; then
  echo 'a failing software observation unexpectedly succeeded' >&2
  exit 1
fi
awk 'index($0, "network_observation_timeout:") { found=1 } END { exit !found }' "$tmp/b.err"
b_failure="$tmp/operator-b/reporting/invocations/invocation.$(latest_failure "$tmp/operator-b")/failure.env"
b_log="$(awk -F= '$1 == "run_log" { print $2 }' "$b_failure")"
[[ -f "$b_log" && ! -L "$b_log" ]]
awk 'index($0, "network_observation_timeout:") { found=1 } END { exit !found }' "$b_log"
[[ "$(find "$tmp/operator-b" -type f -name run.log | wc -l)" == 1 ]]

# Scenario D: after successful observation and profile preparation, failure to
# resolve an official component remains a preflight refusal.  It must be tied
# to the same protected run log, rather than being mistaken for a remote JOIN
# failure or an unavailable log.
if BLOCKLIST_CURL_MODE=component_failure READINESS_MODE=ok \
  GDC_JOIN_PREFLIGHT_DEADLINE=30 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 \
  PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator-component" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --skip-qualification \
  --public-host validator-component.example.test validator-component \
  >"$tmp/component.out" 2>"$tmp/component.err"; then
  echo 'a missing official component unexpectedly entered JOIN' >&2
  exit 1
fi
awk 'index($0, "checkpoint=component-resolution") { found=1 } END { exit !found }' "$tmp/component.err"
component_failure="$tmp/operator-component/reporting/invocations/invocation.$(latest_failure "$tmp/operator-component")/failure.env"
component_log="$(awk -F= '$1 == "run_log" { print $2 }' "$component_failure")"
component_receipt="$(awk -F= '$1 == "preflight_receipt" { print $2 }' "$component_failure")"
[[ -f "$component_log" && ! -L "$component_log" ]]
[[ "$(stat -c %a "$component_log")" == 600 ]]
awk 'index($0, "checkpoint=component-resolution") { found=1 } END { exit !found }' "$component_log"
awk '$0 ~ /^END phase=join-preflight status=[1-9][0-9]* timestamp=/ { found=1 } END { exit !found }' "$component_log"
[[ "$(find "$tmp/operator-component" -type f -name run.log | wc -l)" == 1 ]]
[[ -f "$component_receipt" && ! -L "$component_receipt" ]]
awk -F= '$1 == "checkpoint" && $2 == "component-resolution" { found=1 } END { exit !found }' "$component_receipt"
awk -F= '$1 == "result" && $2 == "failed" { found=1 } END { exit !found }' "$component_receipt"

# Scenario E: component resolution has succeeded, but the Host inspection
# rejects an unsupported accelerator profile. This is still a preflight
# refusal with no deployment transport, and has the same one-log binding.
if BLOCKLIST_CURL_MODE=profile_failure READINESS_MODE=ok ACCELERATOR_MODE=unsupported_profile \
  GDC_JOIN_PREFLIGHT_DEADLINE=30 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 \
  PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator-profile" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --skip-qualification \
  --public-host validator-profile.example.test validator-profile \
  >"$tmp/profile.out" 2>"$tmp/profile.err"; then
  echo 'an unsupported accelerator profile unexpectedly entered JOIN' >&2
  exit 1
fi
awk 'index($0, "checkpoint=accelerator-profile") { found=1 } END { exit !found }' "$tmp/profile.err"
profile_failure="$tmp/operator-profile/reporting/invocations/invocation.$(latest_failure "$tmp/operator-profile")/failure.env"
profile_log="$(awk -F= '$1 == "run_log" { print $2 }' "$profile_failure")"
profile_receipt="$(awk -F= '$1 == "preflight_receipt" { print $2 }' "$profile_failure")"
[[ -f "$profile_log" && ! -L "$profile_log" ]]
[[ "$(stat -c %a "$profile_log")" == 600 ]]
awk 'index($0, "checkpoint=accelerator-profile") { found=1 } END { exit !found }' "$profile_log"
awk '$0 ~ /^END phase=join-preflight status=[1-9][0-9]* timestamp=/ { found=1 } END { exit !found }' "$profile_log"
[[ "$(find "$tmp/operator-profile" -type f -name run.log | wc -l)" == 1 ]]
[[ -f "$profile_receipt" && ! -L "$profile_receipt" ]]
awk -F= '$1 == "checkpoint" && $2 == "accelerator-profile" { found=1 } END { exit !found }' "$profile_receipt"
awk -F= '$1 == "result" && $2 == "failed" { found=1 } END { exit !found }' "$profile_receipt"

if BLOCKLIST_CURL_MODE=profile_failure INFERENCED_CURL_MODE=unavailable READINESS_MODE=ok \
  GDC_JOIN_PREFLIGHT_DEADLINE=30 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator-cli" "$ROOT/gdc.sh" host join --skip-qualification \
  --bootstrap-file "$tmp/bootstrap.json" --public-host validator-cli.example.test validator-cli \
  >"$tmp/cli.out" 2>"$tmp/cli.err"; then
  echo 'an unavailable pinned CLI unexpectedly entered JOIN' >&2
  exit 1
fi
awk 'index($0, "checkpoint=inferenced-cli") { found=1 } END { exit !found }' "$tmp/cli.err"
cli_failure="$tmp/operator-cli/reporting/invocations/invocation.$(latest_failure "$tmp/operator-cli")/failure.env"
cli_log="$(awk -F= '$1 == "run_log" { print $2 }' "$cli_failure")"
cli_receipt="$(awk -F= '$1 == "preflight_receipt" { print $2 }' "$cli_failure")"
[[ -f "$cli_log" && ! -L "$cli_log" && "$(stat -c %a "$cli_log")" == 600 ]]
awk 'index($0, "checkpoint=inferenced-cli") { found=1 } END { exit !found }' "$cli_log"
awk '$0 ~ /^END phase=join-preflight status=[1-9][0-9]* timestamp=/ { found=1 } END { exit !found }' "$cli_log"
[[ "$(find "$tmp/operator-cli" -type f -name run.log | wc -l)" == 1 ]]
[[ -f "$cli_receipt" && ! -L "$cli_receipt" ]]
awk -F= '$1 == "checkpoint" && $2 == "inferenced-cli" { found=1 } END { exit !found }' "$cli_receipt"
awk -F= '$1 == "result" && $2 == "failed" { found=1 } END { exit !found }' "$cli_receipt"

if BLOCKLIST_CURL_MODE=profile_failure READINESS_MODE=ok GDC_JOIN_PREFLIGHT_DEADLINE=30 \
  GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 PATH="$tmp/bin:$PATH" \
  GDC_HOME="$tmp/operator-lineage" "$ROOT/gdc.sh" host join --skip-qualification \
  --bootstrap-file "$tmp/bootstrap.json" --public-host validator-lineage.example.test validator-lineage \
  >"$tmp/lineage.out" 2>"$tmp/lineage.err"; then
  echo 'a failing lineage preflight unexpectedly entered JOIN' >&2
  exit 1
fi
awk 'index($0, "checkpoint=lineage-preflight") { found=1 } END { exit !found }' "$tmp/lineage.err"
lineage_failure="$tmp/operator-lineage/reporting/invocations/invocation.$(latest_failure "$tmp/operator-lineage")/failure.env"
lineage_log="$(awk -F= '$1 == "run_log" { print $2 }' "$lineage_failure")"
lineage_receipt="$(awk -F= '$1 == "preflight_receipt" { print $2 }' "$lineage_failure")"
[[ -f "$lineage_log" && ! -L "$lineage_log" && "$(stat -c %a "$lineage_log")" == 600 ]]
awk 'index($0, "checkpoint=lineage-preflight") { found=1 } END { exit !found }' "$lineage_log"
awk '$0 ~ /^END phase=join-preflight status=[1-9][0-9]* timestamp=/ { found=1 } END { exit !found }' "$lineage_log"
[[ "$(find "$tmp/operator-lineage" -type f -name run.log | wc -l)" == 1 ]]
[[ -f "$lineage_receipt" && ! -L "$lineage_receipt" ]]
awk -F= '$1 == "checkpoint" && $2 == "lineage-preflight" { found=1 } END { exit !found }' "$lineage_receipt"
awk -F= '$1 == "result" && $2 == "failed" { found=1 } END { exit !found }' "$lineage_receipt"

# The reporter may render only safe matching status lines from that log.
if GDC_HOME="$tmp/operator" "$ROOT/gdc.sh" report github </dev/null >"$tmp/report.out" 2>"$tmp/report.err"; then
  echo 'a non-interactive report unexpectedly published' >&2
  exit 1
fi
report_dir="$(awk 'match($0, /\/[^ ]*\/reports\/report\.[A-Za-z0-9]+/) { value=substr($0, RSTART, RLENGTH) } END { print value }' "$tmp/report.err")"
[[ -n "$report_dir" && -f "$report_dir/report.md" ]]
awk 'index($0, "BEGIN phase=join-preflight") { begin=1 } index($0, "END phase=join-preflight status=1") { end=1 } index($0, "run.log") { unsafe=1 } END { exit !(begin && end && !unsafe) }' "$report_dir/report.md"

# A log may contain text that is safe locally but unsuitable for disclosure.
# The Bootstrap-failure run contains the fixture bearer-like value emitted by
# readiness. The report must retain its bounded lifecycle excerpt without
# rendering that value or the local log path.
if GDC_HOME="$tmp/operator-bootstrap" "$ROOT/gdc.sh" report github </dev/null >"$tmp/bootstrap-report.out" 2>"$tmp/bootstrap-report.err"; then
  echo 'a non-interactive Bootstrap report unexpectedly published' >&2
  exit 1
fi
bootstrap_report_dir="$(awk 'match($0, /\/[^ ]*\/reports\/report\.[A-Za-z0-9]+/) { value=substr($0, RSTART, RLENGTH) } END { print value }' "$tmp/bootstrap-report.err")"
[[ -n "$bootstrap_report_dir" && -f "$bootstrap_report_dir/report.md" ]]
awk '
  /BEGIN phase=join-preflight/ { begin=1 }
  /END phase=join-preflight status=/ { end=1 }
  /fixture-run-log-secret|Authorization: Bearer/ { secret=1 }
  /run\.log/ { local_path=1 }
  END { exit !(begin && end && !secret && !local_path) }
' "$bootstrap_report_dir/report.md"

printf 'test-join-run-log-lifecycle: PASS\n'
