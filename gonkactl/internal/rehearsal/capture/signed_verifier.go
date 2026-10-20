package capture

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

// SignedProofVerifier verifies the versioned capture-proof envelopes specified
// in the Core evidence handoff. It establishes only what the signed proof and
// raw Comet bytes establish; it does not turn a historical receipt, a path, or
// a caller assertion into a fresh capture proof.
type SignedProofVerifier struct {
	Roots       []input.TrustRoot
	Revocations input.RevocationSnapshot
	Clock       func() time.Time
}

type signedFreezeProof struct {
	contract.SignedMetadata
	SnapshotID string `json:"snapshot_id"`
	Checkpoint string `json:"checkpoint"`
	Frozen     bool   `json:"frozen"`
}

type signedLayoutProof struct {
	contract.SignedMetadata
	SnapshotID     string   `json:"snapshot_id"`
	Backend        string   `json:"backend"`
	Layout         string   `json:"layout"`
	BackendVersion string   `json:"backend_version"`
	ComponentRoots []string `json:"component_roots"`
}

type signedInventoryProof struct {
	contract.SignedMetadata
	SnapshotID string                `json:"snapshot_id"`
	Files      []contract.ExportFile `json:"files"`
}

type signedWitnessProof struct {
	contract.SignedMetadata
	SourceIdentity     string   `json:"source_identity"`
	BlockID            string   `json:"block_id"`
	BlockHeight        int64    `json:"block_height"`
	AppHash            string   `json:"app_hash"`
	AppHashHeight      int64    `json:"app_hash_height"`
	PartSetHash        string   `json:"part_set_hash"`
	PartSetTotal       uint32   `json:"part_set_total"`
	SeenCommitSHA256   string   `json:"seen_commit_sha256"`
	ValidatorSetSHA256 string   `json:"validator_set_sha256"`
	CommitBase64       string   `json:"commit_base64"`
	ValidatorSetBase64 string   `json:"validator_set_base64"`
	ValidatorSignerIDs []string `json:"validator_signer_ids"`
	SignedVotingPower  uint64   `json:"signed_voting_power"`
	TotalVotingPower   uint64   `json:"total_voting_power"`
}

type signedOfflineReaderProof struct {
	contract.SignedMetadata
	SnapshotID         string   `json:"snapshot_id"`
	ConsensusHeight    int64    `json:"consensus_height"`
	Backend            string   `json:"backend"`
	Layout             string   `json:"layout"`
	BackendVersion     string   `json:"backend_version"`
	ReaderSHA256       string   `json:"reader_sha256"`
	ReaderOutputSHA256 string   `json:"reader_output_sha256"`
	Command            []string `json:"command"`
	ExitCode           *int     `json:"exit_code"`
	ObservedUTC        string   `json:"observed_utc"`
}

var _ ProofVerifier = (*SignedProofVerifier)(nil)

func (v SignedProofVerifier) VerifySnapshotInputs(_ context.Context, b contract.RunBinding, m contract.SourceManifest, freezeRaw, layoutRaw, inventoryRaw []byte) (SnapshotVerification, error) {
	freeze, metadata, err := verifySignedProof[signedFreezeProof](v, b, freezeRaw, "snapshot_freeze", "archive_owner")
	if err != nil {
		return SnapshotVerification{}, err
	}
	layout, _, err := verifySignedProof[signedLayoutProof](v, b, layoutRaw, "layout_proof", "archive_owner")
	if err != nil {
		return SnapshotVerification{}, err
	}
	inventory, _, err := verifySignedProof[signedInventoryProof](v, b, inventoryRaw, "inventory_receipt", "archive_owner")
	if err != nil {
		return SnapshotVerification{}, err
	}
	if !freeze.Frozen || freeze.SnapshotID != m.SnapshotID || freeze.Checkpoint != m.Checkpoint ||
		layout.SnapshotID != m.SnapshotID || layout.Backend != m.Backend || layout.Layout != m.Layout || layout.BackendVersion != m.BackendVersion ||
		inventory.SnapshotID != m.SnapshotID {
		return SnapshotVerification{}, errors.New("signed snapshot proofs disagree with source manifest")
	}
	if !sameExportFiles(inventory.Files, m.Files) {
		return SnapshotVerification{}, errors.New("signed inventory does not exactly match source manifest")
	}
	if len(layout.ComponentRoots) == 0 || !uniqueNonempty(layout.ComponentRoots) {
		return SnapshotVerification{}, errors.New("layout proof must declare unique non-empty component roots")
	}
	filesDigest, err := contract.Digest(m.Files)
	if err != nil {
		return SnapshotVerification{}, err
	}
	binding, err := verificationBinding(b, freezeRaw)
	if err != nil {
		return SnapshotVerification{}, err
	}
	if metadata.KeyID == "" {
		return SnapshotVerification{}, errors.New("freeze proof signer is absent")
	}
	return SnapshotVerification{VerificationBinding: binding, FreezePayloadSHA256: contract.PayloadDigest(freezeRaw), LayoutPayloadSHA256: contract.PayloadDigest(layoutRaw), InventoryPayloadSHA256: contract.PayloadDigest(inventoryRaw), SnapshotID: m.SnapshotID, Backend: m.Backend, Layout: m.Layout, BackendVersion: m.BackendVersion, InventorySHA256: filesDigest, Frozen: true}, nil
}

func (v SignedProofVerifier) VerifyWitness(ctx context.Context, b contract.RunBinding, raw []byte) (WitnessVerification, error) {
	proof, metadata, err := verifySignedProof[signedWitnessProof](v, b, raw, "capture_witness", "witness")
	if err != nil {
		return WitnessVerification{}, err
	}
	if proof.SourceIdentity == "" || proof.BlockID != b.BlockID || proof.BlockHeight != b.Heights.Blockstore || proof.AppHash != b.AppHash || proof.AppHashHeight != b.Heights.App || !contract.IsDigest(proof.PartSetHash) || proof.PartSetTotal == 0 || !contract.IsDigest(proof.SeenCommitSHA256) || !contract.IsDigest(proof.ValidatorSetSHA256) || !uniqueNonempty(proof.ValidatorSignerIDs) {
		return WitnessVerification{}, errors.New("signed witness identity or H/H-1 assertion is invalid")
	}
	commit, err := decodeProofBytes(proof.CommitBase64)
	if err != nil {
		return WitnessVerification{}, fmt.Errorf("decode signed witness commit: %w", err)
	}
	validators, err := decodeProofBytes(proof.ValidatorSetBase64)
	if err != nil {
		return WitnessVerification{}, fmt.Errorf("decode signed witness validator set: %w", err)
	}
	quorum, err := (coregate.CometCommitVerifier{}).VerifySeenCommit(ctx, b.ChainID, commit, validators, proof.BlockID, proof.PartSetHash, proof.PartSetTotal, proof.BlockHeight, proof.SeenCommitSHA256, proof.ValidatorSetSHA256)
	if err != nil {
		return WitnessVerification{}, fmt.Errorf("verify signed witness raw Comet quorum: %w", err)
	}
	if quorum.SignedPower <= 0 || quorum.TotalPower <= 0 || proof.SignedVotingPower != uint64(quorum.SignedPower) || proof.TotalVotingPower != uint64(quorum.TotalPower) || proof.ValidatorSetSHA256 != quorum.ValidatorSetHash {
		return WitnessVerification{}, errors.New("signed witness declared voting power differs from raw Comet proof")
	}
	actualSigners, err := commitSignerIDs(commit)
	if err != nil {
		return WitnessVerification{}, err
	}
	if !sameStringSet(proof.ValidatorSignerIDs, actualSigners) {
		return WitnessVerification{}, errors.New("signed witness signer identities differ from raw Comet commit")
	}
	binding, err := verificationBinding(b, raw)
	if err != nil {
		return WitnessVerification{}, err
	}
	return WitnessVerification{VerificationBinding: binding, SourceIdentity: proof.SourceIdentity, SignerKeyID: metadata.KeyID, BlockID: proof.BlockID, BlockHeight: proof.BlockHeight, AppHash: proof.AppHash, AppHashHeight: proof.AppHashHeight, ValidatorSetSHA256: quorum.ValidatorSetHash, ValidatorSetComplete: true, SignerIDs: append([]string(nil), proof.ValidatorSignerIDs...), SignedVotingPower: proof.SignedVotingPower, TotalVotingPower: proof.TotalVotingPower}, nil
}

func commitSignerIDs(raw []byte) ([]string, error) {
	var commitProto cmtproto.Commit
	if err := proto.Unmarshal(raw, &commitProto); err != nil {
		return nil, fmt.Errorf("decode signed witness commit signers: %w", err)
	}
	commit, err := tmtypes.CommitFromProto(&commitProto)
	if err != nil {
		return nil, fmt.Errorf("convert signed witness commit signers: %w", err)
	}
	ids := make([]string, 0, len(commit.Signatures))
	for _, signature := range commit.Signatures {
		if signature.BlockIDFlag == tmtypes.BlockIDFlagCommit {
			ids = append(ids, hex.EncodeToString(signature.ValidatorAddress))
		}
	}
	if len(ids) == 0 || !uniqueNonempty(ids) {
		return nil, errors.New("raw Comet commit has no unique committing validator identities")
	}
	return ids, nil
}

func sameStringSet(left, right []string) bool {
	if len(left) != len(right) || !uniqueNonempty(left) || !uniqueNonempty(right) {
		return false
	}
	seen := make(map[string]struct{}, len(left))
	for _, value := range left {
		seen[value] = struct{}{}
	}
	for _, value := range right {
		if _, ok := seen[value]; !ok {
			return false
		}
	}
	return true
}

func (v SignedProofVerifier) VerifyOfflineReader(_ context.Context, b contract.RunBinding, raw []byte) (OfflineReaderVerification, error) {
	proof, _, err := verifySignedProof[signedOfflineReaderProof](v, b, raw, "offline_reader", "offline_reader")
	if err != nil {
		return OfflineReaderVerification{}, err
	}
	if proof.SnapshotID == "" || proof.ConsensusHeight < 0 || proof.Backend == "" || proof.Layout == "" || proof.BackendVersion == "" || !contract.IsDigest(proof.ReaderSHA256) || !contract.IsDigest(proof.ReaderOutputSHA256) || len(proof.Command) == 0 || proof.ExitCode == nil || *proof.ExitCode != 0 {
		return OfflineReaderVerification{}, errors.New("offline-reader proof is incomplete")
	}
	observed, err := time.Parse(time.RFC3339, proof.ObservedUTC)
	if err != nil || observed.Location() != time.UTC {
		return OfflineReaderVerification{}, errors.New("offline-reader proof observation time is invalid")
	}
	binding, err := verificationBinding(b, raw)
	if err != nil {
		return OfflineReaderVerification{}, err
	}
	return OfflineReaderVerification{VerificationBinding: binding, SnapshotID: proof.SnapshotID, ConsensusHeight: proof.ConsensusHeight}, nil
}

func verifySignedProof[T any](v SignedProofVerifier, b contract.RunBinding, raw []byte, kind, role string) (T, contract.SignedMetadata, error) {
	var proof T
	document, err := input.DecodeSignedDocument(raw)
	if err != nil {
		return proof, contract.SignedMetadata{}, err
	}
	// The immutable RunBinding pins the exact envelope bytes, including its
	// signature. input.VerifyTypedDocument validates the signed inner payload.
	// Use a private policy copy for that inner digest while Capture separately
	// confirms the envelope digest before calling this verifier. InputBindingDigest
	// excludes InputDigests, so the signed run context remains unchanged.
	policyBinding := b
	policyBinding.InputDigests = cloneInputDigests(b.InputDigests)
	policyBinding.InputDigests[kind] = contract.PayloadDigest(document.Payload)
	policy := input.VerificationPolicy{Kind: kind, Scope: "capture", Role: role, Binding: policyBinding, Roots: v.Roots, Revocations: v.Revocations, Now: v.Clock}
	metadata, err := input.VerifyTypedDocument(document, policy, func(payload []byte) error { return contract.DecodeStrict(payload, &proof) })
	if err != nil {
		return proof, contract.SignedMetadata{}, err
	}
	return proof, metadata, nil
}

func decodeProofBytes(value string) ([]byte, error) {
	if value == "" {
		return nil, errors.New("raw proof bytes are absent")
	}
	return base64.StdEncoding.Strict().DecodeString(value)
}

func sameExportFiles(left, right []contract.ExportFile) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] || left[i].Path == "" || !contract.IsDigest(left[i].SHA256) || left[i].Size < 0 {
			return false
		}
	}
	return true
}
