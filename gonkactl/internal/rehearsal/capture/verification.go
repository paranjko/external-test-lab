package capture

import (
	"context"
	"errors"
	"fmt"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// VerificationBinding ties an independent verifier result to the complete run
// binding and the exact raw proof bytes it examined.
type VerificationBinding struct {
	RunID         string
	ChainID       string
	GenesisSHA256 string
	BindingDigest string
	PayloadSHA256 string
}

type SnapshotVerification struct {
	VerificationBinding
	FreezePayloadSHA256    string
	LayoutPayloadSHA256    string
	InventoryPayloadSHA256 string
	SnapshotID             string
	Backend                string
	Layout                 string
	BackendVersion         string
	InventorySHA256        string
	Frozen                 bool
}

// SourceIdentity identifies the independent RPC/witness source. It is not a
// validator identity and does not stand in for validator signer membership.
type WitnessVerification struct {
	VerificationBinding
	SourceIdentity       string
	BlockID              string
	BlockHeight          int64
	AppHash              string
	AppHashHeight        int64
	ValidatorSetSHA256   string
	ValidatorSetComplete bool
	SignerIDs            []string
	SignedVotingPower    uint64
	TotalVotingPower     uint64
}

type OfflineReaderVerification struct {
	VerificationBinding
	SnapshotID      string
	ConsensusHeight int64
}

// ProofVerifier is an explicit trust boundary. Implementations must verify
// proof signatures/provenance, full pagination and validator voting power;
// raw path/hash references cannot satisfy this interface.
type ProofVerifier interface {
	VerifySnapshotInputs(context.Context, contract.RunBinding, contract.SourceManifest, []byte, []byte, []byte) (SnapshotVerification, error)
	VerifyWitness(context.Context, contract.RunBinding, []byte) (WitnessVerification, error)
	VerifyOfflineReader(context.Context, contract.RunBinding, []byte) (OfflineReaderVerification, error)
}

func verificationBinding(b contract.RunBinding, raw []byte) (VerificationBinding, error) {
	d, e := contract.Digest(b)
	if e != nil {
		return VerificationBinding{}, e
	}
	return VerificationBinding{RunID: b.RunID, ChainID: b.ChainID, GenesisSHA256: b.GenesisSHA256, BindingDigest: d, PayloadSHA256: contract.PayloadDigest(raw)}, nil
}
func matchVerificationBinding(got VerificationBinding, b contract.RunBinding, raw []byte) error {
	want, e := verificationBinding(b, raw)
	if e != nil {
		return e
	}
	if got != want {
		return errors.New("verified proof does not bind exact run context and raw payload")
	}
	return nil
}
func verifySnapshot(v ProofVerifier, ctx context.Context, b contract.RunBinding, m contract.SourceManifest, freeze, layout, inventory []byte) error {
	if v == nil {
		return errors.New("capture proof verifier is unavailable")
	}
	if len(freeze) == 0 || len(layout) == 0 || len(inventory) == 0 {
		return errors.New("freeze, layout and inventory proof payloads are required")
	}
	got, e := v.VerifySnapshotInputs(ctx, b, m, freeze, layout, inventory)
	if e != nil {
		return fmt.Errorf("verify frozen snapshot inputs: %w", e)
	}
	if e = matchVerificationBinding(got.VerificationBinding, b, freeze); e != nil {
		return e
	}
	if got.FreezePayloadSHA256 != contract.PayloadDigest(freeze) || got.LayoutPayloadSHA256 != contract.PayloadDigest(layout) || got.InventoryPayloadSHA256 != contract.PayloadDigest(inventory) {
		return errors.New("snapshot verifier did not bind all exact proof bytes")
	}
	if got.SnapshotID != m.SnapshotID || got.Backend != m.Backend || got.Layout != m.Layout || got.BackendVersion != m.BackendVersion || !got.Frozen {
		return errors.New("verified snapshot identity differs from frozen manifest")
	}
	d, e := contract.Digest(m.Files)
	if e != nil || got.InventorySHA256 != d {
		return errors.New("verified snapshot inventory digest differs from manifest")
	}
	return nil
}
func verifyWitnesses(v ProofVerifier, ctx context.Context, b contract.RunBinding, docs [][]byte) error {
	if v == nil {
		return errors.New("capture proof verifier is unavailable")
	}
	if len(docs) != 2 {
		return errors.New("exactly two witness proof payloads are required")
	}
	sources := map[string]bool{}
	var validatorSet string
	var totalVotingPower uint64
	for _, raw := range docs {
		if len(raw) == 0 {
			return errors.New("witness proof payload is unavailable")
		}
		got, e := v.VerifyWitness(ctx, b, raw)
		if e != nil {
			return fmt.Errorf("verify witness: %w", e)
		}
		if e = matchVerificationBinding(got.VerificationBinding, b, raw); e != nil {
			return e
		}
		if got.SourceIdentity == "" || sources[got.SourceIdentity] {
			return errors.New("witness source identities are missing or not independent")
		}
		sources[got.SourceIdentity] = true
		if got.BlockID != b.BlockID || got.BlockHeight != b.Heights.Blockstore || got.AppHash != b.AppHash || got.AppHashHeight != b.Heights.App {
			return errors.New("verified witness does not match H and H-1 run binding")
		}
		if !got.ValidatorSetComplete || !contract.IsDigest(got.ValidatorSetSHA256) || got.TotalVotingPower == 0 || got.SignedVotingPower > got.TotalVotingPower || !strictlyAboveTwoThirds(got.SignedVotingPower, got.TotalVotingPower) || len(got.SignerIDs) == 0 || !uniqueNonempty(got.SignerIDs) {
			return errors.New("witness verifier did not establish complete validator set and strict greater-than-two-thirds quorum")
		}
		if validatorSet != "" && (got.ValidatorSetSHA256 != validatorSet || got.TotalVotingPower != totalVotingPower) {
			return errors.New("independent witnesses disagree on the complete validator set")
		}
		validatorSet, totalVotingPower = got.ValidatorSetSHA256, got.TotalVotingPower
	}
	return nil
}
func verifyOfflineReader(v ProofVerifier, ctx context.Context, b contract.RunBinding, snapshotID string, raw []byte) error {
	if v == nil {
		return errors.New("capture proof verifier is unavailable")
	}
	if len(raw) == 0 {
		return errors.New("offline reader proof payload is unavailable")
	}
	if b.Heights.Consensus == nil {
		return errors.New("consensus-state height is unknown")
	}
	got, e := v.VerifyOfflineReader(ctx, b, raw)
	if e != nil {
		return fmt.Errorf("verify offline reader: %w", e)
	}
	if e = matchVerificationBinding(got.VerificationBinding, b, raw); e != nil {
		return e
	}
	if got.SnapshotID != snapshotID || got.ConsensusHeight != *b.Heights.Consensus {
		return errors.New("offline reader result does not bind the captured snapshot consensus height")
	}
	return nil
}
func strictlyAboveTwoThirds(signed, total uint64) bool {
	if total == 0 || signed > total {
		return false
	}
	threshold := 2*(total/3) + (2*(total%3))/3
	return signed > threshold
}
func uniqueNonempty(ids []string) bool {
	seen := map[string]bool{}
	for _, id := range ids {
		if id == "" || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}
