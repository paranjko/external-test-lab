//go:build linux

package session

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

func TestVerifyFreshPinsFirstReceiptAndRepeatIsReadOnly(t *testing.T) {
	f := newFreshVerifyFixture(t)
	result, err := VerifyFresh(t.Context(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now)
	if err != nil || result.Verdict != contract.Pass || result.Qualification != "evidence_verified" {
		t.Fatalf("first fresh verification failed: result=%+v err=%v", result, err)
	}
	main, state, _, receipts, err := lifecycle.ReadStoredSnapshot(f.main.Workspace)
	if err != nil || state != contract.Running || !sameBinding(main, f.main) {
		t.Fatalf("verification did not preserve running journal: state=%s err=%v", state, err)
	}
	verify, ok := successfulPhase(receipts, contract.Verify)
	if !ok || !contract.IsDigest(verify.EvidenceDigests[freshResultKey]) {
		t.Fatalf("successful Verify receipt does not pin fresh result: %+v", verify)
	}
	if err := WriteVerification(f.main.Workspace, result); err != nil {
		t.Fatalf("write derived verification: %v", err)
	}
	if err := WriteReportResult(f.main.Workspace, result); err != nil {
		t.Fatalf("write redacted report: %v", err)
	}
	for _, name := range []string{verificationName, reportJSONName, reportMDName} {
		if _, err := os.Stat(filepath.Join(f.main.Workspace, "evidence", name)); err != nil {
			t.Fatalf("expected derived evidence %s: %v", name, err)
		}
	}
	path := filepath.Join(f.main.Workspace, "lifecycle.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	repeated, err := VerifyFresh(t.Context(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now)
	if err != nil || repeated.Verdict != contract.Pass {
		t.Fatalf("repeat fresh verification failed: %+v %v", repeated, err)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("repeat verification rewrote lifecycle journal: %v", err)
	}
}

func TestVerifyFreshRejectsChangedSnapshotOrSignedPolicyWithoutRetry(t *testing.T) {
	f := newFreshVerifyFixture(t)
	original, err := os.ReadFile(filepath.Join(f.main.Workspace, "evidence", snapshotFile(contract.Topology, "before")))
	if err != nil {
		t.Fatal(err)
	}
	changed := append([]byte(nil), original...)
	changed = bytes.Replace(changed, []byte(`"name":"auth"`), []byte(`"name":"bad!"`), 1)
	if bytes.Equal(original, changed) {
		t.Fatal("test snapshot mutation did not apply")
	}
	write0600(t, filepath.Join(f.main.Workspace, "evidence", snapshotFile(contract.Topology, "before")), changed)
	if _, err := VerifyFresh(t.Context(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now); err == nil {
		t.Fatal("changed raw snapshot accepted")
	}
	// Restore the raw file, then change signed bytes without a new signature.
	write0600(t, filepath.Join(f.main.Workspace, "evidence", snapshotFile(contract.Topology, "before")), original)
	f.mainArtifact.Payload = append(json.RawMessage(nil), f.mainArtifact.Payload...)
	f.mainArtifact.Payload[len(f.mainArtifact.Payload)-2] ^= 1
	if _, err := VerifyFresh(t.Context(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now); err == nil {
		t.Fatal("modified signed artifact accepted")
	}
	_, _, _, receipts, err := lifecycle.ReadStoredSnapshot(f.main.Workspace)
	if err != nil {
		t.Fatal(err)
	}
	if hasPhase(receipts, contract.Verify) {
		t.Fatal("failed verification wrote a Verify receipt")
	}
}

func TestVerifyFreshRefusesInterruptedProducerWithoutJournalMutation(t *testing.T) {
	root := t.TempDir()
	binding := testBinding(root, "run-interrupted")
	binding.InputDigests["catalog"] = strings.Repeat("c", 64)
	binding.InputDigests["recovery_artifact"] = strings.Repeat("d", 64)
	peerRoot := filepath.Join(root, "peer")
	binding.Paths["peer_workspace"] = peerRoot
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("capture", contract.Receipt{Phase: contract.Capture}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "lifecycle.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyFresh(t.Context(), root, binding.RunID, contract.SignedDocument{}, contract.SignedDocument{}, contract.SignedDocument{}, contract.SignedDocument{}, nil, input.RevocationSnapshot{}, time.Now); err == nil {
		t.Fatal("interrupted producer journal accepted")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("refusal mutated interrupted journal: %v", err)
	}
}

type freshVerifyFixture struct {
	main, peer                contract.RunBinding
	mainCatalog, mainArtifact contract.SignedDocument
	peerCatalog, peerArtifact contract.SignedDocument
	roots                     []input.TrustRoot
	revocations               input.RevocationSnapshot
	now                       func() time.Time
}

func newFreshVerifyFixture(t *testing.T) freshVerifyFixture {
	t.Helper()
	base := t.TempDir()
	mainRoot := filepath.Join(base, "main")
	peerRoot := filepath.Join(base, "peer")
	height := int64(3)
	main := freshBinding(mainRoot, "fresh-main", "owner-main", height)
	main.Paths["peer_workspace"] = peerRoot
	peer := freshBinding(peerRoot, "fresh-peer", "owner-peer", height)
	seedCatalog := sha256.Sum256([]byte("fresh-verification-catalog-key"))
	seedCore := sha256.Sum256([]byte("fresh-verification-core-key"))
	catalogKey := ed25519.NewKeyFromSeed(seedCatalog[:])
	coreKey := ed25519.NewKeyFromSeed(seedCore[:])
	nowTime := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	now := func() time.Time { return nowTime }
	roots := []input.TrustRoot{
		{KeyID: "catalog", Role: "catalog", Scopes: map[string]bool{catalog.CatalogScope: true}, PublicKey: catalogKey.Public().(ed25519.PublicKey)},
		{KeyID: "core", Role: "core", Scopes: map[string]bool{catalog.ArtifactScope: true}, PublicKey: coreKey.Public().(ed25519.PublicKey)},
	}
	revocations := input.RevocationSnapshot{ValidUntil: nowTime.Add(time.Hour), Revoked: map[string]bool{}}
	mainCatalog, mainArtifact := signedPolicies(t, main, catalogKey, coreKey, nowTime)
	main.InputDigests["catalog"], main.InputDigests["recovery_artifact"] = contract.PayloadDigest(mainCatalog.Payload), contract.PayloadDigest(mainArtifact.Payload)
	peerCatalog, peerArtifact := signedPolicies(t, peer, catalogKey, coreKey, nowTime)
	peer.InputDigests["catalog"], peer.InputDigests["recovery_artifact"] = contract.PayloadDigest(peerCatalog.Payload), contract.PayloadDigest(peerArtifact.Payload)
	if err := contract.ValidateBinding(main); err != nil {
		t.Fatal(err)
	}
	if err := contract.ValidateBinding(peer); err != nil {
		t.Fatal(err)
	}
	createJournal(t, main)
	createJournal(t, peer)
	if err := os.MkdirAll(filepath.Join(mainRoot, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	snapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "auth", Entries: []contract.Entry{}}}}
	writeSnapshots(t, mainRoot, map[string]contract.Snapshot{
		"topology.before": snapshot, "topology.after": snapshot, "migration.before": snapshot, "migration.after": snapshot,
		"block.before": snapshot, "block.after": snapshot,
	})
	writeSnapshots(t, peerRoot, map[string]contract.Snapshot{"migration.before": snapshot, "migration.after": snapshot})
	mainJournal, err := lifecycle.Open(mainRoot, main)
	if err != nil {
		t.Fatal(err)
	}
	if err := recordFreshProducers(mainJournal, snapshot, false); err != nil {
		t.Fatal(err)
	}
	if err := mainJournal.Close(); err != nil {
		t.Fatal(err)
	}
	peerJournal, err := lifecycle.Open(peerRoot, peer)
	if err != nil {
		t.Fatal(err)
	}
	if err := recordFreshProducers(peerJournal, snapshot, true); err != nil {
		t.Fatal(err)
	}
	if err := peerJournal.Close(); err != nil {
		t.Fatal(err)
	}
	return freshVerifyFixture{main: main, peer: peer, mainCatalog: mainCatalog, mainArtifact: mainArtifact, peerCatalog: peerCatalog, peerArtifact: peerArtifact, roots: roots, revocations: revocations, now: now}
}

func freshBinding(root, runID, owner string, height int64) contract.RunBinding {
	return contract.RunBinding{SchemaVersion: contract.Version, RunID: runID, Scenario: contract.Scenario, Workspace: root, OwnershipMarker: owner,
		ChainID: "fixture-chain", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 4, App: 3, Consensus: &height, FirstRepaired: 5},
		BlockID: "block-4", AppHash: "app-3", AppHashHeight: 3, ToolVersion: "fixture-tool", CatalogVersion: "fixture-catalog",
		InputDigests: map[string]string{"source_manifest": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"standard": strings.Repeat("c", 64)}, Paths: map[string]string{}}
}

func signedPolicies(t *testing.T, binding contract.RunBinding, catalogKey, coreKey ed25519.PrivateKey, now time.Time) (contract.SignedDocument, contract.SignedDocument) {
	t.Helper()
	metadata := func(kind, scope, keyID string) contract.SignedMetadata {
		digest, err := contract.InputBindingDigest(binding)
		if err != nil {
			t.Fatal(err)
		}
		return contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: scope, KeyID: keyID, RunID: binding.RunID,
			BindingDigest: digest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}
	}
	stores := []string{"auth"}
	emptyPolicy := &catalog.DomainPolicy{Changes: []catalog.PolicyChange{}}
	buildDigest := strings.Repeat("d", 64)
	scenario := catalog.Scenario{ID: binding.Scenario, Description: "synthetic signed local verification policy", BuildDigests: map[string]string{"core": buildDigest},
		RuntimeDigests: map[string]string{"standard": binding.RuntimeIdentities["standard"]}, Backends: []string{"fixture"}, Layouts: []string{"single"},
		Files: []catalog.FileRule{{Path: "core.bin", Required: true, Kind: "file", Component: "core"}}, BackendVersions: map[string][]string{"fixture": {"v1"}},
		MigrationKeys: []catalog.MigrationKey{}, RequiredStores: &stores, TopologyPolicy: emptyPolicy, BlockPolicy: emptyPolicy,
		Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired}
	catalogPayload, err := json.Marshal(struct {
		contract.SignedMetadata
		Scenarios []catalog.Scenario `json:"scenarios"`
	}{metadata(catalog.CatalogKind, catalog.CatalogScope, "catalog"), []catalog.Scenario{scenario}})
	if err != nil {
		t.Fatal(err)
	}
	catalogDoc := signFreshDocument(catalogKey, catalogPayload)
	artifact := catalog.RecoveryArtifact{ScenarioID: binding.Scenario, BuildDigests: scenario.BuildDigests, RuntimeDigests: scenario.RuntimeDigests,
		Backend: "fixture", BackendVersion: "v1", Layout: "single", Files: []catalog.ArtifactFile{{Path: "core.bin", SHA256: buildDigest, Size: 1, Component: "core"}},
		MigrationKeys: []catalog.MigrationKey{}, RequiredStores: &stores, TopologyPolicy: emptyPolicy, BlockPolicy: emptyPolicy,
		Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired}
	artifactPayload, err := json.Marshal(struct {
		contract.SignedMetadata
		catalog.RecoveryArtifact
	}{metadata(catalog.ArtifactKind, catalog.ArtifactScope, "core"), artifact})
	if err != nil {
		t.Fatal(err)
	}
	return catalogDoc, signFreshDocument(coreKey, artifactPayload)
}

func signFreshDocument(key ed25519.PrivateKey, payload []byte) contract.SignedDocument {
	sum := sha256.Sum256(payload)
	message := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	return contract.SignedDocument{Payload: append(json.RawMessage(nil), payload...), SignatureHex: hex.EncodeToString(ed25519.Sign(key, message))}
}

func writeSnapshots(t *testing.T, root string, snapshots map[string]contract.Snapshot) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	for key, snapshot := range snapshots {
		parts := strings.Split(key, ".")
		raw, err := json.Marshal(snapshot)
		if err != nil {
			t.Fatal(err)
		}
		write0600(t, filepath.Join(root, "evidence", snapshotFile(contract.Domain(parts[0]), parts[1])), raw)
	}
}

func snapshotFile(domain contract.Domain, side string) string {
	return "snapshot-" + string(domain) + "-" + side + ".json"
}

func write0600(t *testing.T, path string, raw []byte) {
	t.Helper()
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
}

func recordFreshProducers(journal *lifecycle.Lifecycle, snapshot contract.Snapshot, peer bool) error {
	digest, err := evidence.SnapshotDigest(snapshot)
	if err != nil {
		return err
	}
	items := []struct {
		phase   contract.Phase
		op      string
		digests map[string]string
	}{
		{contract.Capture, "capture", map[string]string{}}, {contract.Stage, "stage", map[string]string{}},
	}
	if !peer {
		items[0].digests["topology.before"] = digest
		items[1].digests["topology.after"] = digest
	}
	runDigests := map[string]string{"migration.before": digest, "migration.after": digest}
	if !peer {
		runDigests["block.before"], runDigests["block.after"] = digest, digest
	}
	items = append(items, struct {
		phase   contract.Phase
		op      string
		digests map[string]string
	}{contract.Run, "run", runDigests})
	for _, item := range items {
		if err := journal.RecordIntent(item.op, contract.Receipt{Phase: item.phase}); err != nil {
			return err
		}
		if err := journal.RecordResult(contract.Receipt{Phase: item.phase, State: contract.Succeeded, EvidenceDigests: item.digests}); err != nil {
			return err
		}
	}
	return nil
}
