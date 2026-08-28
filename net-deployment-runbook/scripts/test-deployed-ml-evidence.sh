#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ "${1:-}" == -o ]]; do shift 2; done
host="$1"
shift
command="$*"
case "$command" in
  *'docker ps'*)
    [[ "${MOCK_CONTAINER_MODE:-one}" != none ]] || exit 0
    printf '%s-mlnode-1\n' "$host"
    [[ "${MOCK_CONTAINER_MODE:-one}" != two ]] || printf '%s-mlnode-2\n' "$host"
    ;;
  *'/api/v1/inference/up/status'*)
    printf '{"status":"completed","is_running":true,"error":null}\nGDC_HTTP_STATUS=200\n'
    ;;
  *'/v1/models'*)
    printf '{"data":[{"id":"Qwen/Qwen3-0.6B"}]}\nGDC_HTTP_STATUS=200\n'
    ;;
  *'/v1/chat/completions'*)
    cat >/dev/null
    count_file="${MOCK_STATE_DIR:?}/$host.count"
    count=0
    [[ ! -s "$count_file" ]] || read -r count <"$count_file"
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [[ "${MOCK_COMPLETION_MODE:-pass}" == fail ]] || { [[ "$host" == node-a ]] && (( count == 1 )); }; then
      printf '{"error":{"message":"PoC generation is active"}}\nGDC_HTTP_STATUS=503\n'
    else
      printf '{"choices":[{"message":{"content":"GDC_OK"}}]}\nGDC_HTTP_STATUS=200\n'
    fi
    ;;
  *'nvidia-smi'*)
    printf 'Mock GPU, 16384 MiB, 4096 MiB, 12288 MiB\n'
    ;;
  *)
    echo "unexpected mock ssh command: $command" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/bin/ssh"

export PATH="$tmp/bin:$PATH" MOCK_STATE_DIR="$tmp/state"
mkdir -p "$MOCK_STATE_DIR"

GDC_DEPLOYED_ML_EVIDENCE_TIMEOUT_SECONDS=5 \
GDC_DEPLOYED_ML_EVIDENCE_POLL_SECONDS=1 \
  "$ROOT/scripts/capture-deployed-ml-evidence.sh" \
  "$tmp/pass" Qwen/Qwen3-0.6B node-a node-b

for host in node-a node-b; do
  jq -e '.data[0].id == "Qwen/Qwen3-0.6B"' "$tmp/pass/$host/models.json" >/dev/null
  jq -e '.choices[0].message.content == "GDC_OK"' "$tmp/pass/$host/completion.json" >/dev/null
  [[ -s "$tmp/pass/$host/vram.csv" ]]
done
[[ "$(cat "$MOCK_STATE_DIR/node-a.count")" == 2 ]]

if "$ROOT/scripts/capture-deployed-ml-evidence.sh" "$tmp/duplicate" Qwen/Qwen3-0.6B node-a node-a \
  >/dev/null 2>&1; then
  echo 'accepted a duplicate ML Host alias' >&2
  exit 1
fi

if MOCK_CONTAINER_MODE=two GDC_DEPLOYED_ML_EVIDENCE_TIMEOUT_SECONDS=1 \
  GDC_DEPLOYED_ML_EVIDENCE_POLL_SECONDS=1 \
  "$ROOT/scripts/capture-deployed-ml-evidence.sh" "$tmp/containers" Qwen/Qwen3-0.6B node-a \
  >/dev/null 2>&1; then
  echo 'accepted multiple running MLNode containers' >&2
  exit 1
fi

rm -f "$MOCK_STATE_DIR/node-a.count"
if MOCK_COMPLETION_MODE=fail GDC_DEPLOYED_ML_EVIDENCE_TIMEOUT_SECONDS=1 \
  GDC_DEPLOYED_ML_EVIDENCE_POLL_SECONDS=1 \
  "$ROOT/scripts/capture-deployed-ml-evidence.sh" "$tmp/timeout" Qwen/Qwen3-0.6B node-a \
  >/dev/null 2>&1; then
  echo 'accepted a missing deployed ML completion' >&2
  exit 1
fi

printf 'PASS deployed ML evidence uses running Host runtimes and fails closed\n'
