package capture

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

type testProofVerifier struct{ manifest contract.SourceManifest }

func (v testProofVerifier) VerifySnapshotInputs(_ context.Context, b contract.RunBinding, m contract.SourceManifest, freeze, layout, inventory []byte) (SnapshotVerification, error) {
	ctx, _ := verificationBinding(b, freeze)
	d, _ := contract.Digest(m.Files)
	return SnapshotVerification{VerificationBinding: ctx, FreezePayloadSHA256: contract.PayloadDigest(freeze), LayoutPayloadSHA256: contract.PayloadDigest(layout), InventoryPayloadSHA256: contract.PayloadDigest(inventory), SnapshotID: m.SnapshotID, Backend: m.Backend, Layout: m.Layout, BackendVersion: m.BackendVersion, InventorySHA256: d, Frozen: true}, nil
}
func (v testProofVerifier) VerifyWitness(_ context.Context, b contract.RunBinding, raw []byte) (WitnessVerification, error) {
	ctx, _ := verificationBinding(b, raw)
	return WitnessVerification{VerificationBinding: ctx, SourceIdentity: string(raw), BlockID: b.BlockID, BlockHeight: b.Heights.Blockstore, AppHash: b.AppHash, AppHashHeight: b.Heights.App, ValidatorSetSHA256: strings.Repeat("e", 64), ValidatorSetComplete: true, SignerIDs: []string{"validator-1", "validator-2", "validator-3"}, SignedVotingPower: 7, TotalVotingPower: 9}, nil
}
func (v testProofVerifier) VerifyOfflineReader(_ context.Context, b contract.RunBinding, raw []byte) (OfflineReaderVerification, error) {
	ctx, _ := verificationBinding(b, raw)
	h := int64(-1)
	if b.Heights.Consensus != nil {
		h = *b.Heights.Consensus
	}
	return OfflineReaderVerification{VerificationBinding: ctx, SnapshotID: v.manifest.SnapshotID, ConsensusHeight: h}, nil
}

func testAuthorizedAdapter(t *testing.T, base, runID string) (Adapter, contract.RunBinding, contract.SourceManifest) {
	t.Helper()
	workspace := base
	runRoot := fmt.Sprintf("%s/%s", workspace, runID)
	root := runRoot + "/export"
	dest := runRoot + "/source"
	if e := osMkdirAll(runRoot); e != nil {
		t.Fatal(e)
	}
	if e := osMkdirAll(root); e != nil {
		t.Fatal(e)
	}
	body := []byte("source fixture")
	if e := osWriteFile(root+"/data.db", body); e != nil {
		t.Fatal(e)
	}
	hash := sha256.Sum256(body)
	heights := contract.Heights{Blockstore: 4, App: 3, Consensus: int64ptr(4), FirstRepaired: 5}
	now := time.Now().UTC()
	b := contract.RunBinding{SchemaVersion: contract.Version, RunID: runID, Scenario: contract.Scenario, Workspace: workspace, OwnershipMarker: "owner", ChainID: "chain", GenesisSHA256: strings.Repeat("a", 64), Heights: heights, BlockID: "block-4", AppHash: "app-3", AppHashHeight: 3, ToolVersion: "fixture", CatalogVersion: "fixture", RuntimeIdentities: map[string]string{"runtime": "fixture"}, Paths: map[string]string{"source": dest, "export": root}, InputDigests: map[string]string{}}
	m := contract.SourceManifest{SignedMetadata: contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "source_manifest", Scope: "capture", KeyID: "archive-test", RunID: runID, ChainID: b.ChainID, GenesisSHA256: b.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}, SnapshotID: "snapshot-" + runID, Checkpoint: "atomic", Backend: "fixture", Layout: "single", BackendVersion: "v1", Frozen: true, Heights: heights, Files: []contract.ExportFile{{Path: "data.db", SHA256: hex.EncodeToString(hash[:]), Size: int64(len(body))}}, Components: []string{"blockstore"}}
	m.BindingDigest, _ = contract.InputBindingDigest(b)
	source, _ := json.Marshal(m)
	b.InputDigests["source_manifest"] = contract.PayloadDigest(source)
	freeze, layout, inventory, witness1, witness2, offline := []byte("freeze"), []byte("layout"), []byte("inventory"), []byte("rpc-a"), []byte("rpc-b"), []byte("offline-reader")
	for key, raw := range map[string][]byte{"snapshot_freeze": freeze, "layout_proof": layout, "inventory_receipt": inventory, "witness_1": witness1, "witness_2": witness2, "offline_reader": offline} {
		b.InputDigests[key] = contract.PayloadDigest(raw)
	}
	bindingDigest, _ := contract.InputBindingDigest(b)
	approvalPayload, _ := json.Marshal(contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "approval", Scope: "capture", KeyID: "test-operator", RunID: runID, BindingDigest: bindingDigest, ChainID: b.ChainID, GenesisSHA256: b.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)})
	seed := sha256.Sum256([]byte("ephemeral test-only capture approval key"))
	private := ed25519.NewKeyFromSeed(seed[:])
	sourceSum := sha256.Sum256(source)
	sourceMessage := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sourceSum[:]))
	sourceSignature := ed25519.Sign(private, sourceMessage)
	sum := sha256.Sum256(approvalPayload)
	message := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	sig := ed25519.Sign(private, message)
	b.InputDigests["capture_approval"] = contract.PayloadDigest(approvalPayload)
	policy := Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{"data.db"}, Backend: m.Backend, Layout: m.Layout, BackendVersion: m.BackendVersion, MaxBytes: 1024, ReserveBytes: 1}
	rootKey := private.Public().(ed25519.PublicKey)
	trustRoot := input.TrustRoot{KeyID: "archive-test", Role: "archive_owner", Scopes: map[string]bool{"capture": true}, PublicKey: rootKey}
	operatorRoot := input.TrustRoot{KeyID: "test-operator", Role: "operator", Scopes: map[string]bool{"capture": true}, PublicKey: rootKey}
	trust := input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}
	a := Adapter{Root: root, Destination: dest, Policy: policy, SourcePayload: source, SourceDocument: contract.SignedDocument{Payload: source, SignatureHex: hex.EncodeToString(sourceSignature)}, SourcePolicy: input.VerificationPolicy{Kind: "source_manifest", Scope: "capture", Role: "archive_owner", Binding: b, Roots: []input.TrustRoot{trustRoot}, Revocations: trust, Now: func() time.Time { return now }}, Approval: contract.SignedDocument{Payload: approvalPayload, SignatureHex: hex.EncodeToString(sig)}, ApprovalPolicy: input.VerificationPolicy{Kind: "approval", Scope: "capture", Role: "operator", Binding: b, Roots: []input.TrustRoot{operatorRoot}, Revocations: trust, Now: func() time.Time { return now }}, FreezePayload: freeze, LayoutPayload: layout, InventoryPayload: inventory, WitnessPayloads: [][]byte{witness1, witness2}, OfflineReaderPayload: offline, Verifier: testProofVerifier{manifest: m}}
	return a, b, m
}

func osMkdirAll(p string) error            { return os.MkdirAll(p, 0700) }
func osWriteFile(p string, b []byte) error { return os.WriteFile(p, b, 0600) }

type mismatchedSnapshotVerifier struct{ testProofVerifier }

func (v mismatchedSnapshotVerifier) VerifySnapshotInputs(ctx context.Context, b contract.RunBinding, m contract.SourceManifest, freeze, layout, inventory []byte) (SnapshotVerification, error) {
	got, err := v.testProofVerifier.VerifySnapshotInputs(ctx, b, m, freeze, layout, inventory)
	got.RunID = "another-run"
	return got, err
}

func TestAuthorizationFailsClosedBeforeMutation(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*Adapter)
	}{
		{"no verifier", func(a *Adapter) { a.Verifier = nil }},
		{"invalid source signature", func(a *Adapter) { a.SourceDocument.SignatureHex = strings.Repeat("0", 128) }},
		{"wrong approval scope", func(a *Adapter) { a.ApprovalPolicy.Scope = "recovery" }},
		{"verifier summary for another run", func(a *Adapter) { a.Verifier = mismatchedSnapshotVerifier{a.Verifier.(testProofVerifier)} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base := t.TempDir()
			a, b, m := testAuthorizedAdapter(t, base, "run")
			tc.mutate(&a)
			receipt, err := a.Capture(context.Background(), b, m)
			if err == nil || receipt.State == contract.Succeeded {
				t.Fatal("invalid authorization was accepted")
			}
			if _, statErr := os.Stat(a.Destination); !os.IsNotExist(statErr) {
				t.Fatalf("destination was mutated before authorization: %v", statErr)
			}
		})
	}
}

func TestCaptureRechecksCapacityAndInventoryAfterPreflight(t *testing.T) {
	base := t.TempDir()
	a, b, m := testAuthorizedAdapter(t, base, "run")
	ops := defaultOps()
	ops.available = func(string) (int64, error) { return 1, nil }
	receipt, err := a.captureWithOps(context.Background(), b, m, ops)
	if err == nil || receipt.State == contract.Succeeded {
		t.Fatal("changed capacity was not rechecked before mutation")
	}
	if _, statErr := os.Stat(a.Destination); !os.IsNotExist(statErr) {
		t.Fatalf("insufficient capacity created destination: %v", statErr)
	}

	// A changed source after successful preflight fails closed in the copy's
	// exact inventory walk, leaving no success receipt or destination.
	a, b, m = testAuthorizedAdapter(t, base, "run2")
	if err := osWriteFile(a.Root+"/extra.db", []byte("unlisted")); err != nil {
		t.Fatal(err)
	}
	receipt, err = a.Capture(context.Background(), b, m)
	if err == nil || receipt.State == contract.Succeeded {
		t.Fatal("changed inventory was accepted")
	}
	if _, statErr := os.Stat(a.Destination); !os.IsNotExist(statErr) {
		t.Fatalf("inventory mismatch created destination: %v", statErr)
	}
}

func TestAuthorizedCancellationPreservesPartialEvidence(t *testing.T) {
	base := t.TempDir()
	a, b, m := testAuthorizedAdapter(t, base, "run")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ops := defaultOps()
	ops.wrapWriter = func(w io.Writer) io.Writer { return &cancelAfterWrite{Writer: w, cancel: cancel} }
	receipt, err := a.captureWithOps(ctx, b, m, ops)
	if err == nil || receipt.State != contract.Unknown || receipt.EvidenceDigests["partial_payload_sha256"] == "" {
		t.Fatalf("cancellation receipt=%#v err=%v", receipt, err)
	}
	if _, statErr := os.Stat(a.Destination + "/data.db"); statErr != nil {
		t.Fatalf("partial transfer not preserved: %v", statErr)
	}
}

func TestStrictQuorumBoundary(t *testing.T) {
	if strictlyAboveTwoThirds(2, 3) || strictlyAboveTwoThirds(6, 9) || !strictlyAboveTwoThirds(7, 9) || !strictlyAboveTwoThirds(^uint64(0), ^uint64(0)) {
		t.Fatal("strict greater-than-two-thirds boundary is incorrect")
	}
}
