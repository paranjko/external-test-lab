#!/bin/bash
URL=localhost:5050
INTERVAL=60

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

sleep $INTERVAL

q1=$(get prefix_cache_queries_total)
h1=$(get prefix_cache_hits_total)
echo "after:  queries=$q1 hits=$h1"

dq=$((q1 - q0)); dh=$((h1 - h0))
echo "delta:  queries=$dq hits=$dh"
if [ "$dq" -gt 0 ]; then
  python3 -c "print(f'hit rate: {$dh/$dq*100:.1f}%')"
else
  echo "hit rate: n/a (no new requests during interval)"
fi
