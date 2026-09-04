#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECT="$ROOT/scripts/select-runtime-majority.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
tuple_a='{"core":{"application_name":"inference-chain","version":"0.2.15","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"dapi":{"application_name":"decentralized-api","version":"0.2.15-post3","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
tuple_b='{"core":{"application_name":"inference-chain","version":"0.2.15","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"dapi":{"application_name":"decentralized-api","version":"0.2.15-post5","commit":"cccccccccccccccccccccccccccccccccccccccc"}}'
tuple_c='{"core":{"application_name":"inference-chain","version":"0.2.15","commit":"dddddddddddddddddddddddddddddddddddddddd"},"dapi":{"application_name":"decentralized-api","version":"0.2.15-post3","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
root_a=1111111111111111111111111111111111111111
root_b=2222222222222222222222222222222222222222
make_obs() {
  local a=() i=0 tuple root
  for tuple in "$@"; do
    i=$((i + 1)); root="$root_a"; ((i % 2 == 0)) && root="$root_b"
    a+=("$(jq -cn --argjson t "$tuple" --arg id "$(printf '%040x' "$i")" --arg ip "8.8.8.$i" --arg root "$root" '$t + {node_id:$id,remote_ip:$ip,status:"usable",discovery_root_ids:[$root]}')")
  done
  printf '%s\n' "${a[*]}" | jq -cs . >"$tmp/observations.json"
}
run_ok() {
  local quorum="${1:-3}"
  "$SELECT" --observations "$tmp/observations.json" --output "$tmp/result.json" --minimum-quorum "$quorum" --minimum-independent-discovery-roots 2 >/dev/null
}
make_obs "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_c" "$tuple_c" "$tuple_c" "$tuple_c" "$tuple_c" "$tuple_c" "$tuple_c" "$tuple_b" "$tuple_b" "$tuple_b"; run_ok
jq -e '.selected.tuple.dapi.version == "0.2.15-post3" and .selected.tuple.core.commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .dapi_majority_count == 16 and .core_majority_count == 9 and .pair_support_count == 9 and .strict_majority_count == 9 and .selection_stage == "pair" and .selected_discovery_root_count == 2 and (.selected_discovery_root_ids | sort) == ["1111111111111111111111111111111111111111","2222222222222222222222222222222222222222"] and .selected.discovery_root_count == 2' "$tmp/result.json" >/dev/null
cp "$tmp/observations.json" "$tmp/original.json"; jq 'reverse' "$tmp/observations.json" >"$tmp/reversed.json"; "$SELECT" --observations "$tmp/reversed.json" --output "$tmp/reversed-result.json" --minimum-independent-discovery-roots 2 >/dev/null
jq -e '.selected.tuple.dapi.version == "0.2.15-post3" and .selected.tuple.core.commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$tmp/reversed-result.json" >/dev/null
make_obs "$tuple_a" "$tuple_a" "$tuple_b" "$tuple_b"; if run_ok; then exit 1; fi
make_obs "$tuple_a" "$tuple_a" "$tuple_c" "$tuple_c"; if "$SELECT" --observations "$tmp/observations.json" --output "$tmp/core-tie.json" >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "no_strict_majority" and .selection_stage == "core" and .dapi_majority_count == 4 and .core_majority_count == 2 and .pair_support_count == 2 and .selected == null' "$tmp/core-tie.json" >/dev/null
make_obs "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_b" "$tuple_b" "$tuple_b"; if "$SELECT" --observations "$tmp/observations.json" --output "$tmp/tie.json" >/dev/null 2>&1; then exit 1; fi
make_obs "$tuple_a" "$tuple_a" "$tuple_b" "$tuple_b" "$tuple_c"; if "$SELECT" --observations "$tmp/observations.json" --output "$tmp/plurality.json" >/dev/null 2>&1; then exit 1; fi
make_obs "$tuple_a" "$tuple_a" "$tuple_b"; jq '.[1].remote_ip = "8.8.8.1"' "$tmp/observations.json" >"$tmp/conflict.json"; if "$SELECT" --observations "$tmp/conflict.json" --output "$tmp/conflict-result.json" >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "identity_conflict" and .conflicting_node_ids == [] and .conflicting_remote_ips == ["8.8.8.1"]' "$tmp/conflict-result.json" >/dev/null
jq '.[1].node_id = .[0].node_id | .[1].remote_ip = "9.9.9.2"' "$tmp/observations.json" >"$tmp/duplicate-node.json"; if "$SELECT" --observations "$tmp/duplicate-node.json" --output "$tmp/duplicate-node-result.json" >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "identity_conflict" and (.conflicting_node_ids | type == "array" and length == 1) and .conflicting_remote_ips == []' "$tmp/duplicate-node-result.json" >/dev/null
make_obs "$tuple_a" "$tuple_a" "$tuple_a"; jq --argjson b "$tuple_b" '.[1] = .[1] + $b | .[1].node_id = .[0].node_id | .[1].remote_ip = .[0].remote_ip' "$tmp/observations.json" >"$tmp/byzantine.json"; if "$SELECT" --observations "$tmp/byzantine.json" --output "$tmp/byzantine-result.json" >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "identity_conflict" and (.conflicting_node_ids | type == "array" and length == 1) and (.conflicting_remote_ips | type == "array")' "$tmp/byzantine-result.json" >/dev/null
make_obs "$tuple_a" "$tuple_a" "$tuple_b"; jq '.[2].status = "unavailable"' "$tmp/observations.json" >"$tmp/unreachable-minority.json"; if "$SELECT" --observations "$tmp/unreachable-minority.json" --output "$tmp/unreachable-result.json" >/dev/null 2>&1; then exit 1; fi
make_obs "$tuple_a" "$tuple_a"; if "$SELECT" --observations "$tmp/observations.json" --output "$tmp/quorum.json" >/dev/null 2>&1; then exit 1; fi

# One Bootstrap root must not manufacture authority by advertising many peers.
make_obs "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_b"
jq --arg root "$root_a" 'map(.discovery_root_ids = [$root])' "$tmp/observations.json" >"$tmp/one-root-sybil.json"
if "$SELECT" --observations "$tmp/one-root-sybil.json" --output "$tmp/one-root-sybil-result.json" --minimum-quorum 3 --minimum-independent-discovery-roots 2 >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "insufficient_discovery_roots" and .valid_observation_count == 6 and .pair_support_count == 5 and .selected == null and .selected_discovery_root_count == 1 and .selected_discovery_root_ids == ["1111111111111111111111111111111111111111"]' "$tmp/one-root-sybil-result.json" >/dev/null

# Community's reviewed local policy accepts two agreeing addresses, but one
# address and a 1/1 split both fail closed. The standalone default remains 3.
make_obs "$tuple_a" "$tuple_a"; run_ok 2
jq -e '.state == "ready" and .valid_observation_count == 2 and .minimum_quorum == 2 and .strict_majority_count == 2' "$tmp/result.json" >/dev/null
make_obs "$tuple_a"; if "$SELECT" --observations "$tmp/observations.json" --output "$tmp/community-one.json" --minimum-quorum 2 >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "insufficient_quorum" and .minimum_quorum == 2' "$tmp/community-one.json" >/dev/null
make_obs "$tuple_a" "$tuple_b"; if "$SELECT" --observations "$tmp/observations.json" --output "$tmp/community-split.json" --minimum-quorum 2 >/dev/null 2>&1; then exit 1; fi
jq -e '.state == "no_strict_majority" and .strict_majority_count == 1 and .minimum_quorum == 2' "$tmp/community-split.json" >/dev/null

# Conflicting gossip excludes only the affected identities. A strict majority
# among the remaining unique addresses still establishes the tuple.
make_obs "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_a" "$tuple_b"
jq '.[6].node_id = .[5].node_id | .[6].remote_ip = "9.9.9.99"' "$tmp/observations.json" >"$tmp/conflict-with-majority.json"
"$SELECT" --observations "$tmp/conflict-with-majority.json" --output "$tmp/conflict-with-majority-result.json" >/dev/null
jq -e '.state == "ready" and .valid_observation_count == 6 and .strict_majority_count == 5 and (.conflicting_node_ids | length) == 1' "$tmp/conflict-with-majority-result.json" >/dev/null

# Exact duplicate reports from multiple roots are one address vote.
make_obs "$tuple_a" "$tuple_a" "$tuple_a"
jq '. + [.[0]]' "$tmp/observations.json" >"$tmp/duplicate-report.json"
"$SELECT" --observations "$tmp/duplicate-report.json" --output "$tmp/duplicate-report-result.json" >/dev/null
jq -e '.state == "ready" and .valid_observation_count == 3 and .strict_majority_count == 3' "$tmp/duplicate-report-result.json" >/dev/null
make_obs "$tuple_a" "$tuple_a" "$tuple_a"
jq '.[1].remote_ip = "10.0.0.2"' "$tmp/observations.json" >"$tmp/private-address.json"
if "$SELECT" --observations "$tmp/private-address.json" --output "$tmp/private-address-result.json" >"$tmp/private-address.out" 2>"$tmp/private-address.err"; then
  echo 'private observation address unexpectedly influenced selection' >&2; exit 1
fi
grep -Fq 'software_incomplete: usable runtime observation has no public IPv4 address' "$tmp/private-address.err"
python3 - "$ROOT/lineage/network-observation.v1.schema.json" "$tmp/result.json" "$tmp/core-tie.json" "$tmp/conflict-result.json" "$tmp/duplicate-node-result.json" "$tmp/byzantine-result.json" "$tmp/community-one.json" "$tmp/community-split.json" "$tmp/conflict-with-majority-result.json" "$tmp/duplicate-report-result.json" <<'PY'
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

root = json.loads(pathlib.Path(sys.argv[1]).read_text())
authority_schema = {"$schema": root["$schema"], "$ref": "#/$defs/authority", "$defs": root["$defs"]}
Draft202012Validator.check_schema(authority_schema)
validator = Draft202012Validator(authority_schema)
for path in map(pathlib.Path, sys.argv[2:]):
    errors = sorted(validator.iter_errors(json.loads(path.read_text())), key=lambda error: list(error.path))
    if errors:
        raise SystemExit(f"{path}: {errors[0].message}")
PY
printf 'PASS runtime selector: strict majority, configurable local quorum, order independence, duplicate reports, isolated conflicts, ties, plurality, and insufficient quorum\n'
