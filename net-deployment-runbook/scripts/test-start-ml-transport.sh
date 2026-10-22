#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

docker() {
  local invocation="$*" count
  case "$invocation" in
    *'/api/v1/inference/up/status'*)
      # Model Compose exec consuming this stream reproduces the remote script
      # truncation this fixture guards against.
      cat >/dev/null
      if [[ "${GDC_TEST_SCENARIO:?}" == success ]]; then
        count="$(cat "$GDC_TEST_ROOT/status-count" 2>/dev/null || printf 0)"
        count=$((count + 1))
        printf '%s' "$count" >"$GDC_TEST_ROOT/status-count"
        if ((count == 1)); then
          printf '%s\n' '{"status":"not_started"}'
        else
          printf '%s\n' '{"is_running":true}'
        fi
      else
        printf '%s\n' '{"is_running":true}'
      fi
      ;;
    *'/api/v1/inference/up/async'*)
      cat >"$GDC_TEST_ROOT/up-request.json"
      printf '{}\n'
      ;;
    *'/v1/models'*)
      cat >/dev/null
      if [[ "${GDC_TEST_SCENARIO:?}" == success ]]; then
        printf '%s\n' '{"data":[{"id":"Qwen/Qwen3-0.6B"}]}'
      else
        printf '%s\n' '{"data":[{"id":"wrong-model"}]}'
      fi
      ;;
    *'/v1/chat/completions'*)
      cat >"$GDC_TEST_ROOT/completion-request.json"
      printf '%s\n' '{"choices":[{"message":{"content":"GDC_OK"}}]}'
      ;;
    *)
      printf 'unexpected mocked docker invocation: %s\n' "$invocation" >&2
      return 90
      ;;
  esac
}

sudo() { "$@"; }
cd() { [[ "${1:-}" == /srv/dai/deploy ]] && return 0; builtin cd "$@"; }
sleep() { [[ "${GDC_TEST_SCENARIO:-}" != failed-model ]] || SECONDS=2000; }
ssh() {
  [[ "$#" == 3 && "$1" == -T ]] || {
    printf 'unexpected mocked ssh arguments: %s\n' "$*" >&2
    return 91
  }
  shift
  [[ "$2" == *'bash -s' ]] || return 92
  bash -c "$2"
}
export -f docker sudo cd sleep ssh

model_args='["--tensor-parallel-size","1","--dtype","float16","--revision","c1899de289a04d12100db370d81485cdf75e47ca","--max-num-seqs","32","--gpu-memory-utilization","0.45","--max-model-len","2048","--kv-cache-dtype","auto","--kv-cache-memory-bytes","4294967296","--enforce-eager"]'
run_helper() {
  local scenario="$1" output="$tmp/$1.out" error="$tmp/$1.err"
  mkdir -p "$tmp/$scenario"
  if env GDC_TEST_ROOT="$tmp/$scenario" GDC_TEST_SCENARIO="$scenario" \
    bash "$ROOT/03-join/start-local-ml.sh" donor Qwen/Qwen3-0.6B \
      c1899de289a04d12100db370d81485cdf75e47ca float16 1 32 0.45 2048 "$model_args" \
      >"$output" 2>"$error"; then
    return 0
  else
    return $?
  fi
}

if ! run_helper success; then
  echo 'the mocked remote helper did not complete successfully' >&2
  exit 1
fi
grep -Fq 'READY local ML inference serves Qwen/Qwen3-0.6B on donor' "$tmp/success.out"
jq -e --argjson args "$model_args" '
  .model == "Qwen/Qwen3-0.6B" and .dtype == "float16" and .additional_args == $args
' "$tmp/success/up-request.json" >/dev/null
jq -e '.model == "Qwen/Qwen3-0.6B" and .max_tokens == 16' \
  "$tmp/success/completion-request.json" >/dev/null

if run_helper failed-model; then
  echo 'a model mismatch after the startup status check unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'FAILED local ML model endpoint did not serve Qwen/Qwen3-0.6B on donor' "$tmp/failed-model.err"
! grep -Fq 'READY local ML inference' "$tmp/failed-model.out"

printf 'PASS local ML helper transport preserves remote script stdin, sends exact args, and rejects an unserved model\n'
