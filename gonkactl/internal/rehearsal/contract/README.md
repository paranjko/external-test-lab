# Rehearsal protocol v1

This namespace is separate from the frozen live `network recover` contract.
It is a local qualification protocol, not production recovery authorization.

The Go wire types and strict decoders define the versioned schema. Unknown
fields, duplicate JSON keys and trailing documents are rejected. Signed payloads
retain their exact original bytes; binding digests use Go's deterministic JSON
encoding, including sorted map keys. Changing any binding field changes its
digest. Cross-language implementations must reproduce those exact bytes.

To avoid a circular hash, signed metadata `binding_digest` uses the
domain-separated `InputBindingDigest`: the full run context with `input_digests`
set to null. After signing, `input_digests` pins SHA-256 of the exact signed
payload bytes by document kind (`source_manifest`, `recovery_artifact`,
`capture_approval`, `catalog`). A receipt uses the full final binding digest,
including these input hashes. These two digest domains are not interchangeable.

The immutable run binding includes source identity, three heights, exact input
digests, runtime identities, versions, workspace paths and an ownership marker.
Structural validity is not cryptographic authenticity, storage consistency,
runtime isolation or Core qualification. Unknown consensus height permits an
offline preview only, never stage or run.

Receipts bind a phase and operation to the complete run digest, sequence and
predecessor. Journal intents are durable before effects; results and receipts
are durable afterwards. A running operation without a durable result becomes
unknown and quarantined. Unknown, failed and blocked records are not rewritten
into success; reconciliation adds evidence and never replays initialization.

Adapters accept typed bindings, not arbitrary shell commands. Capture reads
only a frozen allowlisted export. Runtime adapters must prove qualification
and isolation before invocation. Cleanup validates ownership and retains
source, control and evidence. Implementations may refuse an unimplemented
adapter; they must not manufacture a success receipt.

Logical snapshots enumerate every store, including empty stores. Keys and
values are bytes. Presence is explicit: absent and empty are different.
Topology, migration and ordinary-block changes are separate domains. Exact
pre/post allowlists are qualification inputs, never inferred from observed
changes. Only migration deltas with identical logical pre-state can be compared
across independent forks. Missing evidence never means PASS.
