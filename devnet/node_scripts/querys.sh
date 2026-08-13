#!/bin/bash
URL=localhost:5050
MODEL="Qwen/Qwen3-0.6B"
PREFIX="You are a helpful coding assistant. Tools: search, edit, run, test. Always explain step by step. $(python3 -c 'print("Context reference material. " * 50)')"

get () {
  curl -s $URL/metrics \
   | grep "^vllm:$1{" \
   | head -n1 \
   | awk '{print $2}' \
   | cut -d. -f1
}

q0=$(get prefix_cache_queries_total)
h0=$(get prefix_cache_hits_total)
echo "before: queries=$q0 hits=$h0"

codes=""
for s in $(seq 1 50); do
  for turn in $(seq 1 5); do
    c=$(curl -s $URL/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"$PREFIX\"},{\"role\":\"user\",\"content\":\"S$s T$turn q$RANDOM\"}],\"max_tokens\":16}" \
      -o /dev/null -w "%{http_code}")
    codes="$codes $c"
  done
done
echo "http codes (sample):${codes:0:60}..."

q1=$(get prefix_cache_queries_total)
h1=$(get prefix_cache_hits_total)
echo "after:  queries=$q1 hits=$h1"

dq=$((q1 - q0)); dh=$((h1 - h0))
echo "delta:  queries=$dq hits=$dh"
if [ "$dq" -gt 0 ]; then
  python3 -c "print(f'hit rate: {$dh/$dq*100:.1f}%')"
else
  echo "hit rate: n/a (requests failed)"
fi
