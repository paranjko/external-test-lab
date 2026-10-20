# Rehearsal observation harness

`Validate` checks typed, ordered observations for one run. `ValidateSuite`
requires a distinct run ID for each requested case. A successful result means
only that the supplied values are internally consistent; it is not a runtime
qualification, Core repair verdict, or proof that referenced evidence files
exist. Callers must populate `VerifiedEvidenceDigests` only from evidence that
their owning adapter has actually read and verified. Result deliberately has
no PASS/runtime-qualified field.

The lifecycle case requires epoch completion, PoC completion, and validator
rotation for each of two consecutive epochs. Each rotation carries a distinct
next validator-set hash, followed by an observed standard-runtime restart at
the configured post-H block. Restart can also be checked as a separate case.
Late-validator catchup is separate and requires a designated validator, a
verified lag interval, exact common height, block ID, AppHash, standard binary
digest, an explicit saved-block-replay or state-sync mode, and a registered
replay evidence digest. Height equality alone cannot satisfy it.
Recovery barrier observations require registered receipts for all three
Coregate stages: handshake replay, already-synced handshake, and consensus
finalize. Each stage must be independently verified by the caller before it is
added to `VerifiedEvidenceDigests`.
One-update and two-update failures are separate, non-success cases; the
typed applied-update count is checked for each. The negative duplicate control
is also separate. Same-H repair is evaluated in
its own case. Validator identity, node identity, positive voting power, and a verified
validator-set hash are separate typed fields. Cases can declare a minimum
active-validator count. A singleton control/reproduction may be consistency
checked as a singleton; it cannot satisfy a case configured to require a
multi-validator set, regardless of how many node IDs appear.

The package tests build synthetic fixtures to test rejection behavior. These
fixtures are not observations from Testermint and cannot qualify a runtime.
The currently recorded governance observations are text summaries containing
node names, heights, AppHashes, and an error boolean. The repeat2 runtime
record is also prose: it records recovery, standard-binary H+1 linkage, two
PoC cycles with on-chain commits, validations, group weights, and validator
sets. It also records an earlier restart that resumed the chain while the
chain was paused; that is not follower catchup. None of these records is a
machine-readable, run-bound observation stream. The harness does not parse
them or promote them to runtime acceptance.

Repeat2 therefore supports the report-level conclusion that two synthetic
PoC cycles reached activation with positive group weights and three validator
identities at later heights. It does not show a validator-set transition
before and after each rotation, a restart after those cycles, an outage in
which the chain advances without the lagging node, or that node's subsequent
block replay/catchup. The records also are not bound to the rehearsal
`RunBinding` or registered raw evidence digests.

## Producer contract for actual evidence

`EncodeTrace`, `DecodeTrace`, and `DecodeAndValidateTrace` provide the strict
JSON wire adapter over the typed `Trace` schema. Decoding rejects unknown or
duplicate object keys, trailing JSON, invalid bindings, and empty streams;
`DecodeAndValidateTrace` then checks the configured run, artifact, event order,
and registered digest references. The owner adapter must produce one document
per independent case run and preserve exact raw evidence files. It must
register their SHA-256 digests only after reading/verifying those files. The
trace binding must identify the immutable run,
source chain/genesis and H, exact recovery and standard executable digests,
and expected H BlockID/AppHash. Every event must include its sequence, run ID,
binding digest, case, height, node ID, consensus validator ID, voting power,
epoch, validator-set hash, selected binary digest, and evidence digest map.
Each rotation event must also bind its next validator-set hash.

Requirements for each acceptance boundary are explicit:

- One-update and two-update inputs must carry distinct typed counts and
  separate failure evidence. A green duplicate reproduction means only that
  failure was reproduced. Same-H repair uses separate barrier evidence.
- TEST-005 needs the exact saved H block, raw seen-commit and validator-set
  bytes, an offline signature verifier result, a signerless standard-binary
  replay failure, and malformed block/commit controls that are rejected.
- TEST-007 needs complete pre/post logical snapshots for every store, explicit
  migration preconditions, an exact migration-only allowlist and a
  forbidden-key negative case. Full-block effects cannot be relabeled as
  migration changes.
- TEST-008 needs both full post-recovery epoch/PoC/rotation sequences, the
  before/after validator-set transition for each rotation, a standard-binary
  restart receipt ordered after the cycles in the same run, and a second independent run whose
  migration-only delta is compared from an identical logical pre-state.
- TEST-011 needs verified validator identities and voting power at the
  asserted height, plus same-H repair receipts for the required validators,
  standard-binary H+1 linkage, and a late-node replay/catchup receipt proving
  it missed blocks and later reached a common block. Node IDs alone never
  establish validator membership.
- TEST-012 needs all three verified commit-barrier stages and intent/result
  receipts for every journal crash boundary, concurrency, ENOSPC, and stale
  receipt case.
- TEST-013 needs the exact one-update and two-update governance inputs, run
  identities, observed duplicate failures, and the ELU-06 receipt.

The current repeat2 prose supports the limited claim that the synthetic H=370
repair was followed by standard-binary H+1 and two PoC cycles with positive
weights and three validator identities at later heights. It does not provide
the event-level run binding, source/artifact/evidence digests, complete
per-validator proof chain, restart-after-two-cycles, late catchup, independent
migration-only oracle, or fault-injection receipts required by these cases.
