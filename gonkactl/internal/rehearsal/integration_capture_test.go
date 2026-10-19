package rehearsal_test

import (
	"context"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/capture"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// integrationProofVerifier is deliberately synthetic. It exercises the
// adapter's exact-byte and full-binding contract but does not verify any real
// witness, snapshot, or offline database evidence.
type integrationProofVerifier struct{}

func (integrationProofVerifier) VerifySnapshotInputs(_ context.Context, binding contract.RunBinding, manifest contract.SourceManifest, freeze, layout, inventory []byte) (capture.SnapshotVerification, error) {
	ctx, err := integrationVerificationBinding(binding, freeze)
	if err != nil {
		return capture.SnapshotVerification{}, err
	}
	inventoryDigest, err := contract.Digest(manifest.Files)
	if err != nil {
		return capture.SnapshotVerification{}, err
	}
	return capture.SnapshotVerification{
		VerificationBinding:    ctx,
		FreezePayloadSHA256:    contract.PayloadDigest(freeze),
		LayoutPayloadSHA256:    contract.PayloadDigest(layout),
		InventoryPayloadSHA256: contract.PayloadDigest(inventory),
		SnapshotID:             manifest.SnapshotID,
		Backend:                manifest.Backend,
		Layout:                 manifest.Layout,
		BackendVersion:         manifest.BackendVersion,
		InventorySHA256:        inventoryDigest,
		Frozen:                 true,
	}, nil
}

func (integrationProofVerifier) VerifyWitness(_ context.Context, binding contract.RunBinding, raw []byte) (capture.WitnessVerification, error) {
	ctx, err := integrationVerificationBinding(binding, raw)
	if err != nil {
		return capture.WitnessVerification{}, err
	}
	return capture.WitnessVerification{
		VerificationBinding:  ctx,
		SourceIdentity:       string(raw),
		BlockID:              binding.BlockID,
		BlockHeight:          binding.Heights.Blockstore,
		AppHash:              binding.AppHash,
		AppHashHeight:        binding.Heights.App,
		ValidatorSetSHA256:   strings.Repeat("c", 64),
		ValidatorSetComplete: true,
		SignerIDs:            []string{"validator-a", "validator-b", "validator-c"},
		SignedVotingPower:    7,
		TotalVotingPower:     9,
	}, nil
}

func (integrationProofVerifier) VerifyOfflineReader(_ context.Context, binding contract.RunBinding, raw []byte) (capture.OfflineReaderVerification, error) {
	ctx, err := integrationVerificationBinding(binding, raw)
	if err != nil {
		return capture.OfflineReaderVerification{}, err
	}
	if binding.Heights.Consensus == nil {
		return capture.OfflineReaderVerification{}, nil
	}
	return capture.OfflineReaderVerification{VerificationBinding: ctx, SnapshotID: "synthetic-freeze-1", ConsensusHeight: *binding.Heights.Consensus}, nil
}

func integrationVerificationBinding(binding contract.RunBinding, raw []byte) (capture.VerificationBinding, error) {
	digest, err := contract.Digest(binding)
	if err != nil {
		return capture.VerificationBinding{}, err
	}
	return capture.VerificationBinding{
		RunID: binding.RunID, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256,
		BindingDigest: digest, PayloadSHA256: contract.PayloadDigest(raw),
	}, nil
}
