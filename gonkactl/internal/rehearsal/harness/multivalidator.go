package harness

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

const MultiValidatorSchemaVersion = "rehearsal-multivalidator/v1"

// ConfiguredNode is an inventory entry. It is not proof that the node has an
// active validator identity or contributes voting power.
type ConfiguredNode struct{ NodeID string }

// ValidatorMember is one identity in the complete persisted validator set.
// This complete set supplies the voting-power denominator.
type ValidatorMember struct {
	ValidatorID string `json:"validator_id"`
	VotingPower int64  `json:"voting_power"`
}

// NodeIdentity maps a configured local node to its observed validator
// identity. An empty ValidatorID means that configured node is not an active
// validator; it still contributes no voting power.
type NodeIdentity struct {
	NodeID      string `json:"node_id"`
	ValidatorID string `json:"validator_id"`
}

// SignerProof is a distinct signer identity plus an evidence registry
// reference. Registry membership proves only that bytes were registered; it
// does not cryptographically verify a validator signature.
type SignerProof struct {
	ValidatorID    string `json:"validator_id"`
	EvidenceDigest string `json:"evidence_digest"`
}

// ValidatorSnapshot binds the full persisted set and observed commit signers
// to one height. EvidenceDigest is the canonical typed-payload digest, which
// must also exist in the caller-owned registry. Registry membership proves
// correspondence only; this object is not a cryptographic quorum verifier.
type ValidatorSnapshot struct {
	SchemaVersion     string            `json:"schema_version"`
	RunID             string            `json:"run_id"`
	BindingDigest     string            `json:"binding_digest"`
	ChainID           string            `json:"chain_id"`
	GenesisSHA256     string            `json:"genesis_sha256"`
	ArtifactDigest    string            `json:"artifact_digest"`
	Height            int64             `json:"height"`
	SetHash           string            `json:"set_hash"`
	Members           []ValidatorMember `json:"members"`
	NodeIdentities    []NodeIdentity    `json:"node_identities"`
	SignerProofs      []SignerProof     `json:"signer_proofs"`
	SetEvidenceDigest string            `json:"set_evidence_digest"`
}

// ValidatorSnapshotDocument keeps the registry reference outside the payload
// it identifies, avoiding a self-referential digest.
type ValidatorSnapshotDocument struct {
	Payload        ValidatorSnapshot `json:"payload"`
	EvidenceDigest string            `json:"evidence_digest"`
}

type MultiValidatorResult struct {
	ConsistencyChecked             bool   `json:"consistency_checked"`
	ConfiguredNodeCount            int    `json:"configured_node_count"`
	ConfiguredActiveValidatorCount int    `json:"configured_active_validator_count"`
	ValidatorSetMemberCount        int    `json:"validator_set_member_count"`
	TotalVotingPower               int64  `json:"total_voting_power"`
	SignedVotingPower              int64  `json:"signed_voting_power"`
	SetHash                        string `json:"set_hash"`
	Reason                         string `json:"reason,omitempty"`
}

var ErrInvalidMultiValidatorEvidence = errors.New("invalid multi-validator evidence")

// ValidateMultiValidator rejects node-count substitution, duplicate validator
// identities, incomplete persisted power inventories and signer power at or
// below two thirds. It checks arithmetic consistency only: it does not verify
// validator signatures or establish an authentic quorum.
func ValidateMultiValidator(binding contract.RunBinding, configured []ConfiguredNode, document ValidatorSnapshotDocument, minimumActive int, expectedHeight int64, expectedSetHash, expectedArtifactDigest string, registeredEvidence map[string]bool) (MultiValidatorResult, error) {
	snapshot := document.Payload
	result := MultiValidatorResult{SetHash: snapshot.SetHash}
	fail := func(format string, args ...any) (MultiValidatorResult, error) {
		result.Reason = fmt.Sprintf(format, args...)
		return result, fmt.Errorf("%w: %s", ErrInvalidMultiValidatorEvidence, result.Reason)
	}
	if err := contract.ValidateBinding(binding); err != nil {
		return fail("invalid run binding: %v", err)
	}
	bindingDigest, err := contract.Digest(binding)
	if err != nil {
		return fail("binding digest unavailable")
	}
	if snapshot.SchemaVersion != MultiValidatorSchemaVersion || snapshot.RunID != binding.RunID || snapshot.BindingDigest != bindingDigest || snapshot.ChainID != binding.ChainID || snapshot.GenesisSHA256 != binding.GenesisSHA256 || snapshot.ArtifactDigest != expectedArtifactDigest || !contract.IsDigest(snapshot.ArtifactDigest) || !runtimeHasDigest(binding, expectedArtifactDigest) {
		return fail("validator snapshot is not bound to this run")
	}
	if expectedHeight <= 0 || expectedHeight != binding.Heights.FirstRepaired || snapshot.Height != expectedHeight || !contract.IsDigest(expectedSetHash) || snapshot.SetHash != expectedSetHash || !contract.IsDigest(snapshot.SetHash) || !contract.IsDigest(expectedArtifactDigest) {
		return fail("validator snapshot height or set hash mismatch")
	}
	if SnapshotEvidenceDigest(snapshot) != document.EvidenceDigest || !contract.IsDigest(document.EvidenceDigest) || !registeredEvidence[document.EvidenceDigest] || !contract.IsDigest(snapshot.SetEvidenceDigest) || !registeredEvidence[snapshot.SetEvidenceDigest] {
		return fail("validator-set proof is missing or unregistered")
	}
	nodes := map[string]bool{}
	for _, node := range configured {
		if node.NodeID == "" || nodes[node.NodeID] {
			return fail("configured node inventory is empty or duplicated")
		}
		nodes[node.NodeID] = true
	}
	if len(nodes) == 0 {
		return fail("configured node inventory is required")
	}
	result.ConfiguredNodeCount = len(nodes)
	validators := map[string]int64{}
	var total int64
	for _, member := range snapshot.Members {
		if member.ValidatorID == "" || member.VotingPower <= 0 {
			return fail("persisted validator identity or voting power is invalid")
		}
		if _, exists := validators[member.ValidatorID]; exists {
			return fail("duplicate validator identity in persisted set")
		}
		if total > int64(^uint64(0)>>1)-member.VotingPower {
			return fail("total voting power overflows")
		}
		total += member.VotingPower
		validators[member.ValidatorID] = member.VotingPower
	}
	if len(validators) == 0 {
		return fail("persisted validator set is required")
	}
	seenNode := map[string]bool{}
	localValidators := map[string]bool{}
	for _, identity := range snapshot.NodeIdentities {
		if identity.NodeID == "" || !nodes[identity.NodeID] || seenNode[identity.NodeID] {
			return fail("node identity mapping is unknown or duplicated")
		}
		seenNode[identity.NodeID] = true
		if identity.ValidatorID != "" {
			if _, ok := validators[identity.ValidatorID]; !ok || localValidators[identity.ValidatorID] {
				return fail("configured node maps to an unknown or duplicate validator identity")
			}
			localValidators[identity.ValidatorID] = true
		}
	}
	if len(seenNode) != len(nodes) {
		return fail("configured nodes lack identity observations")
	}
	if len(localValidators) < minimumActive || minimumActive < 1 {
		return fail("configured nodes do not represent the required number of active validator identities")
	}
	if len(snapshot.SignerProofs) == 0 {
		return fail("commit signer proof is missing")
	}
	signed := map[string]bool{}
	signerEvidence := map[string]bool{}
	var signedPower int64
	for _, proof := range snapshot.SignerProofs {
		id := proof.ValidatorID
		power, ok := validators[id]
		if id == "" || !ok || signed[id] {
			return fail("commit signer identity is unknown or duplicated")
		}
		if !contract.IsDigest(proof.EvidenceDigest) || !registeredEvidence[proof.EvidenceDigest] {
			return fail("commit signer proof is missing or unregistered")
		}
		if signerEvidence[proof.EvidenceDigest] {
			return fail("one evidence object cannot count for multiple signer identities")
		}
		signerEvidence[proof.EvidenceDigest] = true
		signed[id] = true
		if signedPower > int64(^uint64(0)>>1)-power {
			return fail("signed voting power overflows")
		}
		signedPower += power
	}
	// Compare 3*signed > 2*total using arbitrary precision so adversarial
	// int64 values cannot overflow the strict quorum test.
	left := new(big.Int).Mul(big.NewInt(signedPower), big.NewInt(3))
	right := new(big.Int).Mul(big.NewInt(total), big.NewInt(2))
	if left.Cmp(right) <= 0 {
		return fail("signed voting power does not exceed two thirds")
	}
	result.ConsistencyChecked = true
	result.ConfiguredActiveValidatorCount = len(localValidators)
	result.ValidatorSetMemberCount = len(validators)
	result.TotalVotingPower = total
	result.SignedVotingPower = signedPower
	result.Reason = "power threshold arithmetic checked against the full persisted set; signer cryptography is not verified"
	return result, nil
}

type LateReplayProof struct {
	SchemaVersion        string `json:"schema_version"`
	RunID                string `json:"run_id"`
	BindingDigest        string `json:"binding_digest"`
	ChainID              string `json:"chain_id"`
	GenesisSHA256        string `json:"genesis_sha256"`
	ArtifactDigest       string `json:"artifact_digest"`
	ValidatorSetHash     string `json:"validator_set_hash"`
	ValidatorID          string `json:"validator_id"`
	FromHeight           int64  `json:"from_height"`
	ToHeight             int64  `json:"to_height"`
	ReplayMode           string `json:"replay_mode"`
	BlockID              string `json:"block_id"`
	AppHash              string `json:"app_hash"`
	SourceEvidenceDigest string `json:"source_evidence_digest"`
}

// LateReplayDocument separates the payload digest reference from its payload.
type LateReplayDocument struct {
	Payload        LateReplayProof `json:"payload"`
	EvidenceDigest string          `json:"evidence_digest"`
}

// ValidateLateReplay ties a lagging active identity to the common post-lag
// block and requires a registered replay proof; a height claim alone fails.
func ValidateLateReplay(binding contract.RunBinding, active ValidatorSnapshotDocument, document LateReplayDocument, expectedHeight int64, expectedBlockID, expectedAppHash, expectedArtifactDigest string, registeredEvidence map[string]bool) error {
	activeSnapshot := active.Payload
	proof := document.Payload
	if err := contract.ValidateBinding(binding); err != nil {
		return fmt.Errorf("%w: invalid run binding", ErrInvalidMultiValidatorEvidence)
	}
	digest, err := contract.Digest(binding)
	if err != nil {
		return fmt.Errorf("%w: binding digest unavailable", ErrInvalidMultiValidatorEvidence)
	}
	if activeSnapshot.SchemaVersion != MultiValidatorSchemaVersion || SnapshotEvidenceDigest(activeSnapshot) != active.EvidenceDigest || !contract.IsDigest(active.EvidenceDigest) || !registeredEvidence[active.EvidenceDigest] || !contract.IsDigest(activeSnapshot.SetEvidenceDigest) || !registeredEvidence[activeSnapshot.SetEvidenceDigest] {
		return fmt.Errorf("%w: active validator set proof is missing or unregistered", ErrInvalidMultiValidatorEvidence)
	}
	if activeSnapshot.Height != binding.Heights.FirstRepaired || !contract.IsDigest(activeSnapshot.SetHash) {
		return fmt.Errorf("%w: active validator set height or hash is invalid", ErrInvalidMultiValidatorEvidence)
	}
	member := false
	memberIDs := map[string]bool{}
	for _, v := range activeSnapshot.Members {
		if v.ValidatorID == "" || v.VotingPower <= 0 || memberIDs[v.ValidatorID] {
			return fmt.Errorf("%w: malformed active validator set", ErrInvalidMultiValidatorEvidence)
		}
		memberIDs[v.ValidatorID] = true
		if v.ValidatorID == proof.ValidatorID {
			member = true
		}
	}
	local := false
	localCount := 0
	for _, v := range activeSnapshot.NodeIdentities {
		if v.ValidatorID == proof.ValidatorID {
			local = true
			localCount++
		}
	}
	if proof.SchemaVersion != MultiValidatorSchemaVersion || !contract.IsDigest(expectedArtifactDigest) || !runtimeHasDigest(binding, expectedArtifactDigest) || activeSnapshot.RunID != binding.RunID || activeSnapshot.BindingDigest != digest || activeSnapshot.ChainID != binding.ChainID || activeSnapshot.GenesisSHA256 != binding.GenesisSHA256 || activeSnapshot.ArtifactDigest != expectedArtifactDigest || proof.RunID != binding.RunID || proof.BindingDigest != digest || proof.ChainID != binding.ChainID || proof.GenesisSHA256 != binding.GenesisSHA256 || proof.ArtifactDigest != expectedArtifactDigest || proof.ValidatorSetHash != activeSnapshot.SetHash || !member || !local || localCount != 1 {
		return fmt.Errorf("%w: late replay identity is not in the bound active set and configured nodes", ErrInvalidMultiValidatorEvidence)
	}
	if expectedHeight <= binding.Heights.FirstRepaired || expectedBlockID == "" || expectedAppHash == "" || proof.FromHeight >= expectedHeight || proof.FromHeight < binding.Heights.FirstRepaired || proof.ToHeight != expectedHeight || proof.BlockID != expectedBlockID || proof.AppHash != expectedAppHash {
		return fmt.Errorf("%w: late replay does not prove lag convergence at the common block", ErrInvalidMultiValidatorEvidence)
	}
	if proof.ReplayMode != "saved-block-replay" && proof.ReplayMode != "state-sync" {
		return fmt.Errorf("%w: unsupported replay mode", ErrInvalidMultiValidatorEvidence)
	}
	if LateReplayEvidenceDigest(proof) != document.EvidenceDigest || !contract.IsDigest(document.EvidenceDigest) || !registeredEvidence[document.EvidenceDigest] || !contract.IsDigest(proof.SourceEvidenceDigest) || !registeredEvidence[proof.SourceEvidenceDigest] {
		return fmt.Errorf("%w: replay proof is missing or unregistered", ErrInvalidMultiValidatorEvidence)
	}
	return nil
}

// SnapshotEvidenceDigest defines the canonical evidence registry identity for
// this typed snapshot. The digest binds the exact set, node map and signer refs;
// it does not validate the cryptographic signatures referenced by those refs.
func SnapshotEvidenceDigest(snapshot ValidatorSnapshot) string {
	digest, err := contract.Digest(snapshot)
	if err != nil {
		return ""
	}
	return digest
}

// LateReplayEvidenceDigest binds replay facts to the registry entry. The
// registry still does not establish that the source bytes contain a valid
// block signature or independently observed runtime result.
func LateReplayEvidenceDigest(proof LateReplayProof) string {
	digest, err := contract.Digest(proof)
	if err != nil {
		return ""
	}
	return digest
}
func runtimeHasDigest(binding contract.RunBinding, want string) bool {
	for _, identity := range binding.RuntimeIdentities {
		if identity == want {
			return true
		}
	}
	return false
}

// DecodeValidatorSnapshot reads one bounded, duplicate-free JSON object and
// rejects unknown or case-aliased fields before typed decoding.
func DecodeValidatorSnapshot(reader io.Reader) (ValidatorSnapshotDocument, error) {
	var value ValidatorSnapshotDocument
	raw, err := io.ReadAll(io.LimitReader(reader, (1<<20)+1))
	if err != nil {
		return value, err
	}
	if len(raw) > 1<<20 {
		return value, fmt.Errorf("validator snapshot exceeds size limit")
	}
	if err := exactEvidenceKeys(raw, map[string][]string{"": {"payload", "evidence_digest"}, "payload": {"schema_version", "run_id", "binding_digest", "chain_id", "genesis_sha256", "artifact_digest", "height", "set_hash", "members", "node_identities", "signer_proofs", "set_evidence_digest"}, "members": {"validator_id", "voting_power"}, "node_identities": {"node_id", "validator_id"}, "signer_proofs": {"validator_id", "evidence_digest"}}); err != nil {
		return value, err
	}
	if err := contract.DecodeStrict(raw, &value); err != nil {
		return value, err
	}
	if value.Payload.SchemaVersion != MultiValidatorSchemaVersion {
		return value, fmt.Errorf("unsupported validator snapshot schema")
	}
	return value, nil
}

func DecodeLateReplayProof(reader io.Reader) (LateReplayDocument, error) {
	var value LateReplayDocument
	raw, err := io.ReadAll(io.LimitReader(reader, (1<<20)+1))
	if err != nil {
		return value, err
	}
	if len(raw) > 1<<20 {
		return value, fmt.Errorf("late replay proof exceeds size limit")
	}
	if err := exactEvidenceKeys(raw, map[string][]string{"": {"payload", "evidence_digest"}, "payload": {"schema_version", "run_id", "binding_digest", "chain_id", "genesis_sha256", "artifact_digest", "validator_set_hash", "validator_id", "from_height", "to_height", "replay_mode", "block_id", "app_hash", "source_evidence_digest"}}); err != nil {
		return value, err
	}
	if err := contract.DecodeStrict(raw, &value); err != nil {
		return value, err
	}
	if value.Payload.SchemaVersion != MultiValidatorSchemaVersion {
		return value, fmt.Errorf("unsupported late replay proof schema")
	}
	return value, nil
}

func exactEvidenceKeys(raw []byte, schemas map[string][]string) error {
	var root map[string]json.RawMessage
	if err := contract.DecodeStrict(raw, &root); err != nil {
		return err
	}
	if root == nil {
		return fmt.Errorf("evidence must be a JSON object")
	}
	if err := checkEvidenceObject(root, schemas[""]); err != nil {
		return err
	}
	for _, field := range []string{"payload"} {
		if rawPayload, ok := root[field]; ok {
			var payload map[string]json.RawMessage
			if err := contract.DecodeStrict(rawPayload, &payload); err != nil {
				return err
			}
			if err := checkEvidenceObject(payload, schemas[field]); err != nil {
				return fmt.Errorf("%s: %w", field, err)
			}
			for _, nested := range []string{"members", "node_identities", "signer_proofs"} {
				if rawArray, ok := payload[nested]; ok {
					var items []map[string]json.RawMessage
					if err := contract.DecodeStrict(rawArray, &items); err != nil {
						return err
					}
					for _, item := range items {
						if err := checkEvidenceObject(item, schemas[nested]); err != nil {
							return fmt.Errorf("%s: %w", nested, err)
						}
					}
				}
			}
		}
	}
	return nil
}
func checkEvidenceObject(fields map[string]json.RawMessage, expected []string) error {
	if len(fields) != len(expected) {
		return fmt.Errorf("evidence object has missing or unsupported fields")
	}
	allowed := map[string]bool{}
	for _, name := range expected {
		allowed[name] = true
	}
	for name := range fields {
		if !allowed[name] {
			return fmt.Errorf("unexpected exact evidence field %q", name)
		}
	}
	return nil
}
