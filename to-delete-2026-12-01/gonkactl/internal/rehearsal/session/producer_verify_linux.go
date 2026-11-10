//go:build linux

package session

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
)

const (
	producerExpectationInput = "producer_expectation"
	producerManifestInput    = "producer_manifest"
	producerDigestKey        = "producer_evidence_digest"
)

// verifyBoundProducerEvidence is opt-in only when both immutable input pins
// are present. It never treats producer-local manifest metadata as its own
// expectation: the strict expectation document is itself pinned by the
// immutable run binding.
func verifyBoundProducerEvidence(ctx context.Context, root, role string, binding contract.RunBinding) (string, bool, error) {
	expectationDigest, hasExpectation := binding.InputDigests[producerExpectationInput]
	manifestDigest, hasManifest := binding.InputDigests[producerManifestInput]
	if hasExpectation != hasManifest {
		return "", false, fmt.Errorf("%w: producer evidence opt-in requires both expectation and manifest pins", ErrInvalidSession)
	}
	if !hasExpectation {
		return "", false, nil
	}
	if !contract.IsDigest(expectationDigest) || !contract.IsDigest(manifestDigest) {
		return "", false, fmt.Errorf("%w: producer evidence pins are invalid", ErrInvalidSession)
	}
	read := func(name string) ([]byte, error) {
		return readOwnedFile(root, filepath.Join(root, "evidence", name))
	}
	expectationRaw, err := read("producer-expectation.json")
	if err != nil {
		return "", false, fmt.Errorf("read pinned producer expectation: %w", err)
	}
	if contract.PayloadDigest(expectationRaw) != expectationDigest {
		return "", false, fmt.Errorf("%w: producer expectation differs from immutable input pin", ErrInvalidSession)
	}
	var want coregate.ProducerExpectation
	if err := contract.DecodeStrict(expectationRaw, &want); err != nil {
		return "", false, fmt.Errorf("decode pinned producer expectation: %w", err)
	}
	if err := validateProducerExpectationBinding(want, binding); err != nil {
		return "", false, err
	}
	manifestRaw, err := read("producer-manifest.json")
	if err != nil {
		return "", false, fmt.Errorf("read pinned producer manifest: %w", err)
	}
	if contract.PayloadDigest(manifestRaw) != manifestDigest {
		return "", false, fmt.Errorf("%w: producer manifest differs from immutable input pin", ErrInvalidSession)
	}
	commitRaw, err := read("seen_commit.bin")
	if err != nil {
		return "", false, fmt.Errorf("read producer commit: %w", err)
	}
	validatorSetRaw, err := read("validator_set.bin")
	if err != nil {
		return "", false, fmt.Errorf("read producer validator set: %w", err)
	}
	blockRaw, err := read("block-h.bin")
	if err != nil {
		return "", false, fmt.Errorf("read producer Block H: %w", err)
	}
	verified, err := coregate.VerifyProducerEvidence(ctx, manifestRaw, commitRaw, validatorSetRaw, blockRaw, want)
	if err != nil {
		return "", false, fmt.Errorf("verify pinned Core producer evidence: %w", err)
	}
	digest, err := contract.Digest(struct {
		Role              string                        `json:"role"`
		ExpectationSHA256 string                        `json:"expectation_sha256"`
		Verification      coregate.ProducerVerification `json:"verification"`
	}{role, expectationDigest, verified})
	if err != nil {
		return "", false, err
	}
	return digest, true, nil
}

func validateProducerExpectationBinding(want coregate.ProducerExpectation, binding contract.RunBinding) error {
	if binding.Heights.Consensus == nil {
		return fmt.Errorf("%w: producer evidence requires a consensus height", ErrInvalidSession)
	}
	recoveryDigest := binding.InputDigests["recovery-binary"]
	producerDigest := binding.InputDigests["producer-binary"]
	if !contract.IsDigest(recoveryDigest) || want.RunID != binding.RunID || want.ChainID != binding.ChainID ||
		!contract.IsDigest(producerDigest) || want.ProducerSHA256 != producerDigest ||
		want.GenesisSHA256 != binding.GenesisSHA256 || want.RecoveryArtifactSHA256 != recoveryDigest ||
		want.Height != binding.Heights.Blockstore || want.Height != binding.Heights.FirstRepaired ||
		want.CometStateHeight != *binding.Heights.Consensus || want.ValidatorSetHeight != want.Height ||
		want.ApplicationHeight != binding.Heights.App || want.CometStateHeight != binding.Heights.App || want.BlockstoreHeight != binding.Heights.Blockstore ||
		want.ApplicationHeight != want.Height-1 || want.CometStateHeight != want.Height-1 || want.BlockstoreHeight != want.Height ||
		want.BlockID != binding.BlockID || want.HeaderAppHash != binding.AppHash {
		return fmt.Errorf("%w: producer expectation differs from immutable run binding", ErrInvalidSession)
	}
	return nil
}

func verifyProducerPair(ctx context.Context, mainRoot, peerRoot string, mainBinding, peerBinding contract.RunBinding) (string, bool, error) {
	mainOpted, err := hasProducerOptIn(mainBinding)
	if err != nil {
		return "", false, err
	}
	peerOpted, err := hasProducerOptIn(peerBinding)
	if err != nil {
		return "", false, err
	}
	if mainOpted != peerOpted {
		return "", false, fmt.Errorf("%w: producer evidence must be opted in for both independent runs", ErrInvalidSession)
	}
	if !mainOpted {
		return "", false, nil
	}
	mainDigest, mainOptIn, err := verifyBoundProducerEvidence(ctx, mainRoot, "main", mainBinding)
	if err != nil {
		return "", false, err
	}
	peerDigest, peerOptIn, err := verifyBoundProducerEvidence(ctx, peerRoot, "peer", peerBinding)
	if err != nil {
		return "", false, err
	}
	if mainOptIn != peerOptIn {
		return "", false, fmt.Errorf("%w: producer evidence must be opted in for both independent runs", ErrInvalidSession)
	}
	if !mainOptIn {
		return "", false, nil
	}
	digest, err := contract.Digest(struct {
		Main string `json:"main"`
		Peer string `json:"peer"`
	}{mainDigest, peerDigest})
	return digest, true, err
}

func hasProducerOptIn(binding contract.RunBinding) (bool, error) {
	_, expectation := binding.InputDigests[producerExpectationInput]
	_, manifest := binding.InputDigests[producerManifestInput]
	if expectation != manifest {
		return false, fmt.Errorf("%w: producer evidence opt-in requires both expectation and manifest pins", ErrInvalidSession)
	}
	return expectation, nil
}
