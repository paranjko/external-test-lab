//go:build linux

package session

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

const freshResultKey = "fresh_result"

// VerifyFresh performs the first local consistency evaluation from fixed
// run-owned snapshots and signed catalog/artifact documents. It journals a
// Verify intent/result only after evaluation succeeds; it never touches a
// runtime. A subsequent interrupted intent is refused by ReadStoredSnapshot.
func VerifyFresh(ctx context.Context, root, runID string, mainCatalogDoc, mainArtifactDoc, peerCatalogDoc, peerArtifactDoc contract.SignedDocument, roots []input.TrustRoot, revocations input.RevocationSnapshot, now func() time.Time) (evidence.Result, error) {
	if ctx == nil || runID == "" {
		return evidence.Result{}, ErrInvalidSession
	}
	binding, state, revision, mainReceipts, err := lifecycle.ReadStoredSnapshot(root)
	if err != nil || binding.RunID != runID || binding.Workspace != root || state == contract.Unknown {
		return evidence.Result{}, fmt.Errorf("%w: main journal is unavailable or unknown", ErrInvalidSession)
	}
	verifyReceipt, alreadyVerified := successfulPhase(mainReceipts, contract.Verify)
	if hasPhase(mainReceipts, contract.Verify) && !alreadyVerified {
		return evidence.Result{}, fmt.Errorf("%w: duplicate verification records", ErrInvalidSession)
	}
	if alreadyVerified && (verifyReceipt.State != contract.Succeeded || !contract.IsDigest(verifyReceipt.EvidenceDigests[freshResultKey])) {
		return evidence.Result{}, fmt.Errorf("%w: existing verification is not a successful fresh result", ErrInvalidSession)
	}
	if state != contract.Running {
		return evidence.Result{}, fmt.Errorf("%w: run is not in a verifiable running state", ErrInvalidSession)
	}
	peerRoot := binding.Paths["peer_workspace"]
	if peerRoot == "" {
		return evidence.Result{}, fmt.Errorf("%w: bound independent workspace missing", ErrInvalidSession)
	}
	peerBinding, peerState, peerRevision, peerReceipts, err := lifecycle.ReadStoredSnapshot(peerRoot)
	if err != nil || peerBinding.Workspace != peerRoot || peerState == contract.Unknown {
		return evidence.Result{}, fmt.Errorf("%w: independent journal is unavailable or unknown", ErrInvalidSession)
	}
	if peerState != contract.Running {
		return evidence.Result{}, fmt.Errorf("%w: independent run is not in a verifiable running state", ErrInvalidSession)
	}
	mainPolicy, err := authenticatedPolicy(binding, mainCatalogDoc, mainArtifactDoc, roots, revocations, now)
	if err != nil {
		return evidence.Result{}, fmt.Errorf("verify main signed recovery policy: %w", err)
	}
	peerPolicy, err := authenticatedPolicy(peerBinding, peerCatalogDoc, peerArtifactDoc, roots, revocations, now)
	if err != nil {
		return evidence.Result{}, fmt.Errorf("verify independent signed recovery policy: %w", err)
	}
	domains := make([]evidence.FreshDomain, 0, 3)
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		before, err := readPinnedSnapshot(root, domain, "before", mainReceipts)
		if err != nil {
			return evidence.Result{}, err
		}
		after, err := readPinnedSnapshot(root, domain, "after", mainReceipts)
		if err != nil {
			return evidence.Result{}, err
		}
		domains = append(domains, evidence.FreshDomain{Domain: domain, Before: before, After: after})
	}
	peerBefore, err := readPinnedSnapshot(peerRoot, contract.Migration, "before", peerReceipts)
	if err != nil {
		return evidence.Result{}, err
	}
	peerAfter, err := readPinnedSnapshot(peerRoot, contract.Migration, "after", peerReceipts)
	if err != nil {
		return evidence.Result{}, err
	}
	mainProducer, err := producerOnly(mainReceipts, true)
	if err != nil {
		return evidence.Result{}, err
	}
	peerProducer, err := producerOnly(peerReceipts, false)
	if err != nil {
		return evidence.Result{}, err
	}
	producerDigest, producerOptIn, err := verifyProducerPair(ctx, root, peerRoot, binding, peerBinding)
	if err != nil {
		return evidence.Result{}, err
	}
	result := evidence.EvaluateFresh(evidence.FreshInput{SchemaVersion: evidence.Version, Binding: binding, PeerBinding: peerBinding,
		Domains: domains, PeerMigrationBefore: peerBefore, PeerMigrationAfter: peerAfter,
		MainProducerReceipts: mainProducer, PeerProducerReceipts: peerProducer, MainPolicy: mainPolicy, PeerPolicy: peerPolicy})
	if producerOptIn {
		result.ProducerEvidenceDigest = producerDigest
	}
	if result.Verdict != contract.Pass || result.Qualification != "evidence_verified" {
		return result, nil
	}
	payloadDigest, err := evidence.FreshPayloadDigest(result)
	if err != nil {
		return evidence.Result{}, err
	}
	if alreadyVerified {
		if verifyReceipt.EvidenceDigests[freshResultKey] != payloadDigest {
			return evidence.Result{}, fmt.Errorf("%w: fresh evidence changed since successful verification", ErrInvalidSession)
		}
		result.Receipts = append([]contract.Receipt(nil), mainReceipts...)
		return result, nil
	}
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		return evidence.Result{}, fmt.Errorf("open journal for verification receipt: %w", err)
	}
	defer journal.Close()
	lockedBinding, lockedState, lockedRevision, lockedReceipts := journal.Snapshot()
	if !sameBinding(binding, lockedBinding) || lockedRevision != revision || lockedState != state || !sameReceipts(mainReceipts, lockedReceipts) || lockedState == contract.Unknown {
		return evidence.Result{}, fmt.Errorf("%w: journal changed during verification", ErrInvalidSession)
	}
	if _, ok := successfulPhase(lockedReceipts, contract.Verify); ok {
		return evidence.Result{}, fmt.Errorf("%w: verification was concurrently recorded", ErrInvalidSession)
	}
	currentPeerBinding, currentPeerState, currentPeerRevision, currentPeerReceipts, peerErr := lifecycle.ReadStoredSnapshot(peerRoot)
	if peerErr != nil || !sameBinding(peerBinding, currentPeerBinding) || currentPeerState != peerState || currentPeerRevision != peerRevision || !sameReceipts(peerReceipts, currentPeerReceipts) || currentPeerState == contract.Unknown {
		return evidence.Result{}, fmt.Errorf("%w: independent journal changed during verification", ErrInvalidSession)
	}
	intent := contract.Receipt{Phase: contract.Verify, Operation: "fresh_evidence_verify", EvidenceDigests: map[string]string{freshResultKey: payloadDigest}}
	_, err = journal.Execute(ctx, "fresh_evidence_verify", intent, verifyReceiptAdapter{digest: payloadDigest})
	if err != nil {
		return evidence.Result{}, err
	}
	_, _, _, persistedReceipts := journal.Snapshot()
	result.Receipts = persistedReceipts
	return result, nil
}

func hasPhase(receipts []contract.Receipt, phase contract.Phase) bool {
	for _, receipt := range receipts {
		if receipt.Phase == phase {
			return true
		}
	}
	return false
}

type verifyReceiptAdapter struct{ digest string }

func (a verifyReceiptAdapter) Execute(_ context.Context, _ contract.RunBinding, operation string) (contract.Receipt, error) {
	if operation != "fresh_evidence_verify" || !contract.IsDigest(a.digest) {
		return contract.Receipt{}, errors.New("invalid local verification receipt request")
	}
	return contract.Receipt{Phase: contract.Verify, Operation: operation, State: contract.Succeeded, EvidenceDigests: map[string]string{freshResultKey: a.digest}}, nil
}

func authenticatedPolicy(binding contract.RunBinding, catalogDoc, artifactDoc contract.SignedDocument, roots []input.TrustRoot, revocations input.RevocationSnapshot, now func() time.Time) (evidence.AuthenticatedPolicy, error) {
	verify := func(kind, scope, role string) input.VerificationPolicy {
		return input.VerificationPolicy{Kind: kind, Scope: scope, Role: role, Binding: binding, Roots: roots, Revocations: revocations, Now: now}
	}
	approved, err := catalog.VerifyCatalog(catalogDoc, catalog.Policy{Scope: catalog.CatalogScope, Verification: verify(catalog.CatalogKind, catalog.CatalogScope, "catalog")})
	if err != nil {
		return evidence.AuthenticatedPolicy{}, err
	}
	artifact, err := catalog.VerifyArtifact(artifactDoc, catalog.Policy{Scope: catalog.ArtifactScope, Verification: verify(catalog.ArtifactKind, catalog.ArtifactScope, "core")}, approved)
	if err != nil {
		return evidence.AuthenticatedPolicy{}, err
	}
	if artifact.RequiredStores == nil || len(*artifact.RequiredStores) == 0 {
		return evidence.AuthenticatedPolicy{}, errors.New("signed required-store inventory is absent")
	}
	policy := evidence.AuthenticatedPolicy{CatalogDigest: contract.PayloadDigest(catalogDoc.Payload), ArtifactDigest: contract.PayloadDigest(artifactDoc.Payload), RequiredStores: append([]string(nil), (*artifact.RequiredStores)...), Allowlist: make(map[contract.Domain][]evidence.ExpectedChange)}
	if artifact.TopologyPolicy != nil {
		changes, err := projectPolicy(artifact.TopologyPolicy.Changes)
		if err != nil {
			return evidence.AuthenticatedPolicy{}, err
		}
		policy.Allowlist[contract.Topology] = changes
	}
	if artifact.MigrationKeys != nil {
		changes, err := projectMigration(artifact.MigrationKeys)
		if err != nil {
			return evidence.AuthenticatedPolicy{}, err
		}
		policy.Allowlist[contract.Migration] = changes
	}
	if artifact.BlockPolicy != nil {
		changes, err := projectPolicy(artifact.BlockPolicy.Changes)
		if err != nil {
			return evidence.AuthenticatedPolicy{}, err
		}
		policy.Allowlist[contract.Block] = changes
	}
	return policy, nil
}

func projectPolicy(in []catalog.PolicyChange) ([]evidence.ExpectedChange, error) {
	out := make([]evidence.ExpectedChange, 0, len(in))
	for _, item := range in {
		key, err := hex.DecodeString(item.KeyHex)
		if err != nil {
			return nil, errors.New("signed policy key is not hex")
		}
		out = append(out, evidence.ExpectedChange{Store: item.Store, Key: key, BeforePresent: item.BeforePresent, BeforeSHA256: item.BeforeSHA256, AfterPresent: item.AfterPresent, AfterSHA256: item.AfterSHA256})
	}
	return out, nil
}

func projectMigration(in []catalog.MigrationKey) ([]evidence.ExpectedChange, error) {
	out := make([]evidence.ExpectedChange, 0, len(in))
	for _, item := range in {
		key, err := hex.DecodeString(item.KeyHex)
		if err != nil {
			return nil, errors.New("signed migration key is not hex")
		}
		out = append(out, evidence.ExpectedChange{Store: item.Store, Key: key, BeforePresent: item.BeforePresent, BeforeSHA256: item.BeforeSHA256, AfterPresent: item.AfterPresent, AfterSHA256: item.AfterSHA256})
	}
	return out, nil
}

func readPinnedSnapshot(root string, domain contract.Domain, side string, receipts []contract.Receipt) (contract.Snapshot, error) {
	name := fmt.Sprintf("snapshot-%s-%s.json", domain, side)
	raw, err := readOwnedFile(root, filepath.Join(root, "evidence", name))
	if err != nil {
		return contract.Snapshot{}, fmt.Errorf("read run-owned %s %s snapshot: %w", domain, side, err)
	}
	var snapshot contract.Snapshot
	if err := contract.DecodeStrict(raw, &snapshot); err != nil {
		return snapshot, fmt.Errorf("decode run-owned %s %s snapshot: %w", domain, side, err)
	}
	digest, err := evidence.SnapshotDigest(snapshot)
	if err != nil {
		return snapshot, fmt.Errorf("validate run-owned %s %s snapshot: %w", domain, side, err)
	}
	phase := contract.Run
	if domain == contract.Topology {
		if side == "before" {
			phase = contract.Capture
		} else {
			phase = contract.Stage
		}
	}
	key := string(domain) + "." + side
	producer, ok := successfulPhase(receipts, phase)
	if !ok || producer.EvidenceDigests[key] != digest {
		return snapshot, fmt.Errorf("%w: %s snapshot is not pinned by successful %s producer", ErrInvalidSession, key, phase)
	}
	return snapshot, nil
}

func producerOnly(receipts []contract.Receipt, allowVerify bool) ([]contract.Receipt, error) {
	out := make([]contract.Receipt, 0, len(receipts))
	for _, receipt := range receipts {
		if receipt.Phase == contract.Verify {
			if allowVerify {
				continue
			}
			return nil, fmt.Errorf("%w: independent verification receipt is unexpected", ErrInvalidSession)
		}
		if receipt.Phase != contract.Capture && receipt.Phase != contract.Stage && receipt.Phase != contract.Run {
			return nil, fmt.Errorf("%w: unexpected producer phase", ErrInvalidSession)
		}
		out = append(out, receipt)
	}
	return out, nil
}

func sameReceipts(a, b []contract.Receipt) bool {
	da, errA := contract.Digest(a)
	db, errB := contract.Digest(b)
	return errA == nil && errB == nil && da == db
}
