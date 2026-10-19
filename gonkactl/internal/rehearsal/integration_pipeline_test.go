package rehearsal_test

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/capture"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

// This synthetic test exercises the actual trust, catalog, capture, journal,
// evidence, and report APIs together. Its evidence verifies local fixture
// consistency only; the fixture is not a runtime or Core qualification.
func TestSignedCatalogCaptureFlowsIntoPersistedSessionEvidence(t *testing.T) {
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	parent := t.TempDir()
	workspace := filepath.Join(parent, "run-main")
	peerWorkspace := filepath.Join(workspace, "run-peer")
	exportRoot := filepath.Join(workspace, "export")
	sourceRoot := filepath.Join(workspace, "source")
	consensus := int64(3)
	genesis := strings.Repeat("a", 64)
	coreDigest := digestText("synthetic-core-build")
	runtimeDigest := digestText("synthetic-standard-runtime")
	fileBytes := []byte("synthetic immutable blockstore fragment")
	fileDigest := digestBytes(fileBytes)
	inputDigests := map[string]string{
		catalog.CatalogKind:  strings.Repeat("0", 64),
		catalog.ArtifactKind: strings.Repeat("0", 64),
		"source_manifest":    strings.Repeat("0", 64),
	}
	binding := contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "integration-main", Scenario: contract.Scenario,
		Workspace: workspace, OwnershipMarker: "synthetic-main-owner", ChainID: "fixture-chain", GenesisSHA256: genesis,
		Heights: contract.Heights{Blockstore: 4, App: 3, Consensus: &consensus, FirstRepaired: 5},
		BlockID: "fixture-block-4", AppHash: "fixture-app-hash-3", AppHashHeight: 3,
		ToolVersion: "integration-fixture", CatalogVersion: "synthetic-catalog-v1",
		InputDigests: inputDigests, RuntimeIdentities: map[string]string{"standard": runtimeDigest},
		Paths: map[string]string{"export": exportRoot, "source": sourceRoot, "peer_workspace": peerWorkspace},
	}
	peerBinding := binding
	peerBinding.RunID = "integration-peer"
	peerBinding.Workspace = peerWorkspace
	peerBinding.OwnershipMarker = "synthetic-peer-owner"
	peerBinding.Paths = map[string]string{}
	if err := contract.ValidateBinding(binding); err != nil {
		t.Fatalf("main fixture binding: %v", err)
	}
	if err := contract.ValidateBinding(peerBinding); err != nil {
		t.Fatalf("peer fixture binding: %v", err)
	}

	archivePrivate, archivePublic := integrationKey("archive owner")
	catalogPrivate, catalogPublic := integrationKey("catalog authority")
	corePrivate, corePublic := integrationKey("core maintainer")
	operatorPrivate, operatorPublic := integrationKey("capture operator")
	roots := []input.TrustRoot{
		{KeyID: "archive-fixture", Role: "archive_owner", Scopes: map[string]bool{"capture": true}, PublicKey: archivePublic},
		{KeyID: "catalog-fixture", Role: "catalog", Scopes: map[string]bool{catalog.CatalogScope: true}, PublicKey: catalogPublic},
		{KeyID: "core-fixture", Role: "core", Scopes: map[string]bool{catalog.ArtifactScope: true}, PublicKey: corePublic},
		{KeyID: "operator-fixture", Role: "operator", Scopes: map[string]bool{"capture": true}, PublicKey: operatorPublic},
	}
	policyFor := func(binding contract.RunBinding, kind, scope, role string) input.VerificationPolicy {
		return input.VerificationPolicy{Kind: kind, Scope: scope, Role: role, Binding: binding, Roots: roots,
			Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}},
			Now:         func() time.Time { return now }}
	}

	manifest := contract.SourceManifest{
		SignedMetadata: contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "source_manifest", Scope: "capture", KeyID: "archive-fixture",
			RunID: binding.RunID, BindingDigest: inputBindingDigest(t, binding), ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256,
			IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)},
		SnapshotID: "synthetic-freeze-1", Checkpoint: "checkpoint-4", Backend: "fixture", Layout: "single", BackendVersion: "fixture-v1",
		Frozen: true, Heights: binding.Heights,
		Files:      []contract.ExportFile{{Path: "block.db", SHA256: fileDigest, Size: int64(len(fileBytes))}},
		Components: []string{"blockstore"},
	}
	sourcePayload, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests["source_manifest"] = contract.PayloadDigest(sourcePayload)
	sourceDocument := integrationSignedDocument(t, archivePrivate, sourcePayload)
	if _, err := input.VerifySourceManifest(sourceDocument, policyFor(binding, "source_manifest", "capture", "archive_owner")); err != nil {
		t.Fatalf("signed source manifest rejected: %v", err)
	}

	scenario := catalog.Scenario{
		ID: catalog.CatalogScope, Description: "synthetic integration scenario",
		BuildDigests: map[string]string{"core": coreDigest}, RuntimeDigests: map[string]string{"standard": runtimeDigest},
		Backends: []string{"fixture"}, Layouts: []string{"single"}, BackendVersions: map[string][]string{"fixture": {"fixture-v1"}},
		Files:         []catalog.FileRule{{Path: "block.db", Required: true, Kind: "file", Component: "blockstore"}},
		MigrationKeys: []catalog.MigrationKey{}, Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired,
	}
	catalogPayload, err := json.Marshal(struct {
		contract.SignedMetadata
		Scenarios []catalog.Scenario `json:"scenarios"`
	}{integrationMetadata(t, binding, catalog.CatalogKind, catalog.CatalogScope, "catalog-fixture", now), []catalog.Scenario{scenario}})
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests[catalog.CatalogKind] = contract.PayloadDigest(catalogPayload)
	catalogPolicy := catalog.Policy{Scope: catalog.CatalogScope, Verification: policyFor(binding, catalog.CatalogKind, catalog.CatalogScope, "catalog")}
	encodedCatalog, err := json.Marshal(integrationSignedDocument(t, catalogPrivate, catalogPayload))
	if err != nil {
		t.Fatal(err)
	}
	catalogDocument, err := catalog.DecodeEnvelope(encodedCatalog)
	if err != nil {
		t.Fatal(err)
	}
	verifiedCatalog, err := catalog.VerifyCatalog(catalogDocument, catalogPolicy)
	if err != nil {
		t.Fatalf("signed catalog rejected: %v", err)
	}

	artifact := catalog.RecoveryArtifact{
		ScenarioID: scenario.ID, BuildDigests: scenario.BuildDigests, RuntimeDigests: scenario.RuntimeDigests,
		Backend: "fixture", BackendVersion: "fixture-v1", Layout: "single",
		Files:         []catalog.ArtifactFile{{Path: "block.db", SHA256: fileDigest, Size: int64(len(fileBytes)), Component: "blockstore"}},
		MigrationKeys: scenario.MigrationKeys, Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired,
	}
	artifactPayload, err := json.Marshal(struct {
		contract.SignedMetadata
		catalog.RecoveryArtifact
	}{integrationMetadata(t, binding, catalog.ArtifactKind, catalog.ArtifactScope, "core-fixture", now), artifact})
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests[catalog.ArtifactKind] = contract.PayloadDigest(artifactPayload)
	// InputBindingDigest intentionally excludes input digests, so signatures
	// issued before the final three payload hashes still bind the same context.
	catalogPolicy.Verification.Binding = binding
	encodedArtifact, err := json.Marshal(integrationSignedDocument(t, corePrivate, artifactPayload))
	if err != nil {
		t.Fatal(err)
	}
	artifactDocument, err := catalog.DecodeEnvelope(encodedArtifact)
	if err != nil {
		t.Fatal(err)
	}
	artifactPolicy := catalog.Policy{Scope: catalog.ArtifactScope, Verification: policyFor(binding, catalog.ArtifactKind, catalog.ArtifactScope, "core")}
	verifiedArtifact, err := catalog.VerifyArtifact(artifactDocument, artifactPolicy, verifiedCatalog)
	if err != nil {
		t.Fatalf("signed recovery artifact rejected: %v", err)
	}
	if err := contract.ValidateBinding(binding); err != nil {
		t.Fatalf("final main run binding: %v", err)
	}
	if err := contract.ValidateBinding(peerBinding); err != nil {
		t.Fatalf("final peer run binding: %v", err)
	}

	// Proof payloads and scoped operator approval are frozen into the full run
	// binding before journals or evidence-oracle snapshots are created.
	freezeProof, layoutProof, inventoryProof := []byte("synthetic freeze receipt"), []byte("synthetic layout proof"), []byte("synthetic inventory receipt")
	witnessOne, witnessTwo, offlineReader := []byte("synthetic rpc witness one"), []byte("synthetic rpc witness two"), []byte("synthetic offline reader receipt")
	for key, raw := range map[string][]byte{"snapshot_freeze": freezeProof, "layout_proof": layoutProof, "inventory_receipt": inventoryProof, "witness_1": witnessOne, "witness_2": witnessTwo, "offline_reader": offlineReader} {
		binding.InputDigests[key] = contract.PayloadDigest(raw)
	}
	approvalPayload, err := json.Marshal(integrationMetadata(t, binding, "approval", "capture", "operator-fixture", now))
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests["capture_approval"] = contract.PayloadDigest(approvalPayload)
	approvalDocument := integrationSignedDocument(t, operatorPrivate, approvalPayload)
	if err := contract.ValidateBinding(binding); err != nil {
		t.Fatalf("fully pinned capture binding: %v", err)
	}

	// Open both persisted run journals before placing the bound export and
	// oracle beneath them. The main capture receipt comes from the real adapter.
	mainJournal, err := lifecycle.Open(workspace, binding)
	if err != nil {
		t.Fatal(err)
	}
	defer mainJournal.Close()
	peerJournal, err := lifecycle.Open(peerWorkspace, peerBinding)
	if err != nil {
		t.Fatal(err)
	}
	defer peerJournal.Close()
	if err := os.Mkdir(exportRoot, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(exportRoot, "block.db"), fileBytes, 0600); err != nil {
		t.Fatal(err)
	}
	manifest, err = input.DecodeSourceManifest(sourceDocument)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(workspace, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}

	mainSnapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "fixture-store", Entries: []contract.Entry{
		{Key: []byte("private-token-value"), Value: []byte("/synthetic/private/path")},
	}}}}
	peerSnapshot := mainSnapshot
	mainSnapshotDigest, err := evidence.SnapshotDigest(mainSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	peerSnapshotDigest, err := evidence.SnapshotDigest(peerSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	oracle := evidence.Oracle{SchemaVersion: evidence.Version, Binding: binding, PeerBinding: peerBinding,
		RequiredStores: []string{"fixture-store"}, PeerPreState: &peerSnapshot, PeerPostState: &peerSnapshot}
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		oracle.Domains = append(oracle.Domains, contract.DomainEvidence{Domain: domain, Before: mainSnapshot, After: mainSnapshot, Allowlist: []contract.Change{}})
	}
	oracleBytes, err := json.Marshal(oracle)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "evidence", "oracle.json"), oracleBytes, 0600); err != nil {
		t.Fatal(err)
	}

	if err := mainJournal.RecordIntent("frozen_export_copy", contract.Receipt{Phase: contract.Capture}); err != nil {
		t.Fatal(err)
	}
	capturePolicy, err := capture.PolicyFromVerifiedArtifact(verifiedArtifact, binding, 1<<20, 0)
	if err != nil {
		t.Fatal(err)
	}
	captureAdapter := capture.Adapter{
		Root: exportRoot, Destination: sourceRoot, Policy: capturePolicy,
		SourcePayload: sourcePayload, SourceDocument: sourceDocument,
		SourcePolicy: policyFor(binding, "source_manifest", "capture", "archive_owner"),
		Approval:     approvalDocument, ApprovalPolicy: policyFor(binding, "approval", "capture", "operator"),
		FreezePayload: freezeProof, LayoutPayload: layoutProof, InventoryPayload: inventoryProof,
		WitnessPayloads: [][]byte{witnessOne, witnessTwo}, OfflineReaderPayload: offlineReader,
		Verifier: integrationProofVerifier{},
	}
	blockedAdapter := captureAdapter
	blockedAdapter.Verifier = nil
	blockedReceipt, blockedErr := blockedAdapter.Capture(context.Background(), binding, manifest)
	if blockedErr == nil || blockedReceipt.State == contract.Succeeded {
		t.Fatal("capture without an explicit proof verifier was accepted")
	}
	if _, statErr := os.Lstat(sourceRoot); !os.IsNotExist(statErr) {
		t.Fatalf("missing-verifier rejection mutated destination: %v", statErr)
	}
	captureReceipt, err := captureAdapter.Capture(context.Background(), binding, manifest)
	if err != nil {
		t.Fatalf("verified-catalog capture failed: %v", err)
	}
	if captureReceipt.State != contract.Succeeded || captureReceipt.EvidenceDigests["payload_sha256"] == "" {
		t.Fatalf("capture did not return durable evidence: %+v", captureReceipt)
	}
	if err := mainJournal.RecordResult(captureReceipt); err != nil {
		t.Fatal(err)
	}
	if err := recordSyntheticSuccess(mainJournal, contract.Stage, "init", map[string]string{"fixture.stage": mainSnapshotDigest}, "fixture-only stage; no runtime invoked"); err != nil {
		t.Fatal(err)
	}
	if err := recordSyntheticSuccess(mainJournal, contract.Run, "fixture-run", map[string]string{"fixture.run": mainSnapshotDigest}, "fixture-only run; no runtime invoked"); err != nil {
		t.Fatal(err)
	}
	if err := recordSyntheticSuccess(peerJournal, contract.Capture, "fixture-capture", map[string]string{"fixture.capture": peerSnapshotDigest}, "independent synthetic fixture; no export copied"); err != nil {
		t.Fatal(err)
	}
	if err := recordSyntheticSuccess(peerJournal, contract.Stage, "init", map[string]string{"fixture.stage": peerSnapshotDigest}, "fixture-only stage; no runtime invoked"); err != nil {
		t.Fatal(err)
	}
	if err := recordSyntheticSuccess(peerJournal, contract.Run, "fixture-run", map[string]string{"fixture.run": peerSnapshotDigest}, "fixture-only run; no runtime invoked"); err != nil {
		t.Fatal(err)
	}
	if err := recordSyntheticSuccess(peerJournal, contract.Verify, "fixture-verify", map[string]string{
		"migration.before": peerSnapshotDigest, "migration.after": peerSnapshotDigest,
	}, "fixture-only evidence; no runtime observed"); err != nil {
		t.Fatal(err)
	}
	mainVerifyDigests := map[string]string{"oracle": contract.PayloadDigest(oracleBytes)}
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		mainVerifyDigests[string(domain)+".before"] = mainSnapshotDigest
		mainVerifyDigests[string(domain)+".after"] = mainSnapshotDigest
	}
	if err := recordSyntheticSuccess(mainJournal, contract.Verify, "fixture-verify", mainVerifyDigests, "fixture-only evidence; no runtime observed"); err != nil {
		t.Fatal(err)
	}
	if err := peerJournal.Close(); err != nil {
		t.Fatal(err)
	}
	if err := mainJournal.Close(); err != nil {
		t.Fatal(err)
	}

	result, err := session.Verify(workspace, binding.RunID)
	if err != nil {
		t.Fatalf("persisted journal/oracle verification failed: %v", err)
	}
	if result.Verdict != contract.Pass || result.Qualification != "evidence_verified" {
		t.Fatalf("synthetic local evidence did not verify: %+v", result)
	}
	if err := session.WriteVerification(workspace, result); err != nil {
		t.Fatal(err)
	}
	reportResult, err := session.WriteReport(workspace, binding.RunID)
	if err != nil {
		t.Fatalf("persisted report failed: %v", err)
	}
	if reportResult.Verdict != contract.Pass || reportResult.Qualification != "evidence_verified" {
		t.Fatalf("report changed local evidence verdict: %+v", reportResult)
	}
	for _, name := range []string{"report.json", "report.md"} {
		contents, err := os.ReadFile(filepath.Join(workspace, "evidence", name))
		if err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{"private-token-value", "/synthetic/private/path", workspace, peerWorkspace} {
			if strings.Contains(string(contents), secret) {
				t.Fatalf("redacted report %s leaked %q", name, secret)
			}
		}
		if strings.Contains(string(contents), "runtime_qualified") {
			t.Fatalf("local evidence report %s claimed runtime qualification", name)
		}
	}
	if got, err := os.ReadFile(filepath.Join(sourceRoot, "block.db")); err != nil || string(got) != string(fileBytes) {
		t.Fatalf("captured artifact differs from frozen source: %q, %v", got, err)
	}
}

func recordSyntheticSuccess(journal *lifecycle.Lifecycle, phase contract.Phase, operation string, digests map[string]string, reason string) error {
	if err := journal.RecordIntent(operation, contract.Receipt{Phase: phase}); err != nil {
		return err
	}
	return journal.RecordResult(contract.Receipt{Phase: phase, State: contract.Succeeded, EvidenceDigests: digests, Reason: reason})
}

func integrationMetadata(t *testing.T, binding contract.RunBinding, kind, scope, keyID string, now time.Time) contract.SignedMetadata {
	t.Helper()
	return contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: scope, KeyID: keyID,
		RunID: binding.RunID, BindingDigest: inputBindingDigest(t, binding), ChainID: binding.ChainID,
		GenesisSHA256: binding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}
}

func inputBindingDigest(t *testing.T, binding contract.RunBinding) string {
	if t == nil {
		panic("test handle unavailable")
	}
	digest, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	return digest
}

func digestBytes(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func digestText(value string) string { return digestBytes([]byte(value)) }

func integrationKey(label string) (ed25519.PrivateKey, ed25519.PublicKey) {
	seed := sha256.Sum256([]byte(label))
	private := ed25519.NewKeyFromSeed(seed[:])
	return private, private.Public().(ed25519.PublicKey)
}

func integrationSignedDocument(t *testing.T, private ed25519.PrivateKey, payload []byte) contract.SignedDocument {
	t.Helper()
	sum := sha256.Sum256(payload)
	message := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	return contract.SignedDocument{Payload: append(json.RawMessage(nil), payload...), SignatureHex: hex.EncodeToString(ed25519.Sign(private, message))}
}
