#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/scripts/publish-running-host-recovery.sh"
CHECK="$ROOT/scripts/evaluate-running-host-recovery.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

node=gdc-node1
address=gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
runtime_id="qwen3-0.6b:$address"
run_id=test-recovery
runtime_file="$tmp/data/state/runtime-identities/runtime.env"
join_file="$tmp/node/state/join-state/$node.env"
joined_marker="$tmp/node/state/joined/$node"
evidence_source="$tmp/decision-source"
evidence_target="$tmp/run/decision-evidence-test"
receipt_source="$tmp/receipt.pass.json"
verdict_source="$tmp/verdict.pass.md"
receipt_target="$tmp/run/receipt.json"
verdict_target="$tmp/run/verdict.md"

install -d -m 0700 "$evidence_source"
printf 'decision-boundary\n' >"$evidence_source/decision-boundary.marker"
touch -d '1 second ago' "$evidence_source/decision-boundary.marker"
printf '{"ready":true}\n' >"$evidence_source/status.json"
printf '{"active":true}\n' >"$evidence_source/participant.json"
printf '{"voting_power":1}\n' >"$evidence_source/validator-set.json"
printf '{"signed":true}\n' >"$evidence_source/commit.json"
printf '{"matched":true}\n' >"$evidence_source/runtime.json"
printf '{"matched":true}\n' >"$evidence_source/synchronization.json"
"$CHECK" freshness 30 "$evidence_source/decision-boundary.marker" \
  "$evidence_source/status.json" "$evidence_source/participant.json" \
  "$evidence_source/validator-set.json" "$evidence_source/commit.json" \
  "$evidence_source/runtime.json" "$evidence_source/synchronization.json" \
  >"$evidence_source/freshness.json"

jq -n --arg node "$node" --arg address "$address" --arg runtime_id "$runtime_id" \
  --arg evidence_bundle "$(basename "$evidence_target")" \
  --slurpfile evidence "$evidence_source/freshness.json" '
  {schema_version:1,verdict:"PASS",node:$node,participant_address:$address,
   runtime_id:$runtime_id,decision_evidence_bundle:$evidence_bundle,
   decision_evidence:$evidence[0],remote_identity_write:false}
' >"$receipt_source"
printf '# Existing Host operator-state recovery: PASS\n' >"$verdict_source"

args=("$node" "$address" "$runtime_id" "$run_id" "$runtime_file" "$join_file" \
  "$joined_marker" "$evidence_source" "$evidence_target" "$receipt_source" \
  "$verdict_source" "$receipt_target" "$verdict_target")

# The publication clock advances beyond the frozen decision window without a
# sleep. No durable PASS-related target may appear when publication expires.
expired_root="$tmp/expired"
expired_evidence_target="$expired_root/run/decision-evidence-test"
expired_args=("$node" "$address" "$runtime_id" "$run_id" \
  "$expired_root/data/runtime.env" "$expired_root/node/join.env" \
  "$expired_root/node/joined" "$evidence_source" "$expired_evidence_target" \
  "$receipt_source" "$verdict_source" "$expired_root/run/receipt.json" \
  "$expired_root/run/verdict.md")
evaluated_at="$(jq -er .evaluated_at_unix "$evidence_source/freshness.json")"
max_age="$(jq -er .max_age_seconds "$evidence_source/freshness.json")"
expired_now=$((evaluated_at + max_age + 1))
if env GDC_RECOVERY_PUBLICATION_TEST_MODE=true \
  GDC_RECOVERY_PUBLICATION_NOW_UNIX="$expired_now" \
  "$PUBLISH" "${expired_args[@]}" 2>"$tmp/expired.err"; then
  echo 'expired recovery decision unexpectedly published' >&2
  exit 1
fi
grep -Fq 'freshness expired before publication' "$tmp/expired.err"
for unpublished in \
  "$expired_root/data/runtime.env" "$expired_root/node/join.env" \
  "$expired_root/node/joined" "$expired_root/run/receipt.json" \
  "$expired_root/run/verdict.md" "$expired_evidence_target"; do
  [[ ! -e "$unpublished" ]] || {
    echo "expired recovery decision created publication state: $unpublished" >&2
    exit 1
  }
done

# A deterministic test clock crosses a one-second decision window after an
# earlier PASS verdict rename. The durable files remain retry-safe, but without
# the joined marker no PASS has been committed.
race_root="$tmp/commit-race"
race_evidence_source="$tmp/race-decision-source"
race_evidence_target="$race_root/run/decision-evidence-test"
race_receipt_source="$tmp/race-receipt.pass.json"
race_verdict_source="$tmp/race-verdict.pass.md"
cp -a -- "$evidence_source" "$race_evidence_source"
race_freshness_tmp="$tmp/race-freshness.json"
jq '.max_age_seconds = 1' "$race_evidence_source/freshness.json" \
  >"$race_freshness_tmp"
mv -f -- "$race_freshness_tmp" "$race_evidence_source/freshness.json"
jq -n --arg node "$node" --arg address "$address" --arg runtime_id "$runtime_id" \
  --arg evidence_bundle "$(basename "$race_evidence_target")" \
  --slurpfile evidence "$race_evidence_source/freshness.json" '
  {schema_version:1,verdict:"PASS",node:$node,participant_address:$address,
   runtime_id:$runtime_id,decision_evidence_bundle:$evidence_bundle,
   decision_evidence:$evidence[0],remote_identity_write:false}
' >"$race_receipt_source"
printf '# Existing Host operator-state recovery: PASS\n' >"$race_verdict_source"
race_evaluated_at="$(jq -er .evaluated_at_unix "$race_evidence_source/freshness.json")"
race_args=("$node" "$address" "$runtime_id" "$run_id" \
  "$race_root/data/runtime.env" "$race_root/node/join.env" \
  "$race_root/node/joined" "$race_evidence_source" "$race_evidence_target" \
  "$race_receipt_source" "$race_verdict_source" "$race_root/run/receipt.json" \
  "$race_root/run/verdict.md")
if env GDC_RECOVERY_PUBLICATION_TEST_MODE=true \
  GDC_RECOVERY_PUBLICATION_NOW_UNIX="$race_evaluated_at" \
  GDC_RECOVERY_PUBLICATION_TEST_ADVANCE_AFTER=verdict \
  "$PUBLISH" "${race_args[@]}" 2>"$tmp/commit-race.err"; then
  echo 'expired recovery decision unexpectedly committed after earlier writes' >&2
  exit 1
fi
grep -Fq 'freshness expired before publication' "$tmp/commit-race.err"
[[ -s "$race_root/run/receipt.json" && -s "$race_root/run/verdict.md" ]]
[[ ! -e "$race_root/node/joined" ]]

if env GDC_RECOVERY_PUBLICATION_TEST_STOP_AFTER=join_state "$PUBLISH" "${args[@]}"; then
  echo 'publication interruption fixture unexpectedly succeeded' >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 97 ]]
[[ -s "$receipt_target" && -s "$verdict_target" && -s "$runtime_file" && -s "$join_file" ]]
[[ -s "$evidence_target/freshness.json" ]]
[[ ! -e "$joined_marker" ]]

"$PUBLISH" "${args[@]}"
grep -Fxq "runtime_id=$runtime_id" "$runtime_file"
grep -Fxq 'state=ACTIVE' "$join_file"
receipt_sha256="$(sha256sum "$receipt_target" | awk '{print $1}')"
grep -Fxq "receipt_sha256=$receipt_sha256" "$joined_marker"
[[ "$(stat -c '%a' "$joined_marker")" == 600 ]]
diff -qr "$evidence_source" "$evidence_target" >/dev/null

# A complete repeat is deterministic and retains the same binding.
"$PUBLISH" "${args[@]}"
grep -Fxq "receipt_sha256=$receipt_sha256" "$joined_marker"

# A conflicting runtime record fails before changing the commit marker.
before_marker="$(sha256sum "$joined_marker")"
sed -i 's/^participant_address=.*/participant_address=gonka1pppppppppppppppppppppppppppppppppppppp/' "$runtime_file"
if "$PUBLISH" "${args[@]}" 2>"$tmp/conflict.err"; then
  echo 'conflicting runtime record unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'conflicts with the recovered Host' "$tmp/conflict.err"
[[ "$(sha256sum "$joined_marker")" == "$before_marker" ]]

# A symlink target is rejected without following it.
rm -f "$runtime_file" "$joined_marker"
printf 'outside\n' >"$tmp/outside"
ln -s "$tmp/outside" "$joined_marker"
if "$PUBLISH" "${args[@]}" 2>"$tmp/symlink.err"; then
  echo 'symlink publication target unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'symbolic link' "$tmp/symlink.err"
grep -Fxq outside "$tmp/outside"

# Snapshot tampering is rejected before any PASS state can be committed.
rm -f "$joined_marker"
printf '{"ready":false}\n' >"$evidence_source/status.json"
if "$PUBLISH" "${args[@]}" 2>"$tmp/tamper.err"; then
  echo 'tampered decision snapshot unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'status hash does not match freshness evidence' "$tmp/tamper.err"
[[ ! -e "$joined_marker" ]]

echo 'running Host recovery publication tests passed'
