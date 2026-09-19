package recovery

import "encoding/json"

const ManifestSchema = "recovery.schema.json#/$defs/manifest"
const ApprovalPayloadSchema = "recovery.schema.json#/$defs/approval_payload"
const ApprovalSchema = "recovery.schema.json#/$defs/approval"
const PhaseProofSchema = "recovery.schema.json#/$defs/phase_proof"

type Input struct {
	Manifest json.RawMessage `json:"manifest"`
	Proof    json.RawMessage `json:"proof"`
}
