//go:build linux

package session

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

func TestReadOnlyLoadRejectsUnknownWithoutRewritingJournal(t *testing.T) {
	root := t.TempDir()
	binding := testBinding(root, "run-unknown")
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
	if _, err := Load(root, binding.RunID); err == nil {
		t.Fatal("unknown interrupted run was accepted")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("read-only load rewrote the unknown lifecycle journal")
	}
}

func TestLoadRejectsRunIDMismatchEscapeAndSymlink(t *testing.T) {
	root := t.TempDir()
	binding := testBinding(root, "run-safe")
	createJournal(t, binding)
	if _, err := Load(root, "run-other"); err == nil {
		t.Fatal("mismatched run ID accepted")
	}
	if _, err := Load(filepath.Join(root, "..", "escape"), binding.RunID); err == nil {
		t.Fatal("non-clean escaped root accepted")
	}
	link := filepath.Join(t.TempDir(), "run-link")
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(link, binding.RunID); err == nil {
		t.Fatal("symlinked run root accepted")
	}
}

func TestLoadMissingRunDoesNotCreateWorkspace(t *testing.T) {
	root := filepath.Join(t.TempDir(), "missing-run")
	if _, err := Load(root, "missing-run"); err == nil {
		t.Fatal("missing run accepted")
	}
	if _, err := os.Lstat(root); !os.IsNotExist(err) {
		t.Fatalf("read-only load created missing workspace: %v", err)
	}
}

func TestVerifyRejectsOracleChangedAfterJournalDigestWasRecorded(t *testing.T) {
	root := t.TempDir()
	binding := testBinding(root, "run-main")
	createJournal(t, binding)
	if err := os.Mkdir(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	oracle := evidence.Oracle{SchemaVersion: evidence.Version, Binding: binding}
	raw, err := json.Marshal(oracle)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "evidence", oracleName), raw, 0600); err != nil {
		t.Fatal(err)
	}
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("verify", contract.Receipt{Phase: contract.Verify}); err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordResult(contract.Receipt{Phase: contract.Verify, State: contract.Succeeded, EvidenceDigests: map[string]string{"oracle": contract.PayloadDigest(raw)}}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	oracle.Preview = true
	changed, err := json.Marshal(oracle)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "evidence", oracleName), changed, 0600); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(root, "lifecycle.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Verify(root, binding.RunID); err == nil || !strings.Contains(err.Error(), "oracle digest") {
		t.Fatalf("oracle changed after journal binding accepted: %v", err)
	}
	after, err := os.ReadFile(filepath.Join(root, "lifecycle.json"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("oracle digest refusal rewrote journal: %v", err)
	}
}

func TestVerifyRejectsOracleBoundToDifferentRun(t *testing.T) {
	root := t.TempDir()
	binding := testBinding(root, "run-expected")
	createJournal(t, binding)
	oracle := evidence.Oracle{SchemaVersion: evidence.Version, Binding: testBinding(root, "run-forged")}
	raw, err := json.Marshal(oracle)
	if err != nil {
		t.Fatal(err)
	}
	writeOracleAndVerifyReceipt(t, root, binding, raw)
	if _, err := Verify(root, binding.RunID); err == nil || !strings.Contains(err.Error(), "oracle run binding mismatch") {
		t.Fatalf("oracle bound to another run accepted: %v", err)
	}
}

func TestVerifyUsesPersistedPeerJournalInsteadOfOracleReceipts(t *testing.T) {
	mainRoot := t.TempDir()
	peerRoot := filepath.Join(mainRoot, "peer-run")
	mainBinding := testBinding(mainRoot, "peer-main")
	mainBinding.Paths["peer_workspace"] = peerRoot
	peerBinding := testBinding(peerRoot, "peer-independent")
	peerBinding.OwnershipMarker = "independent-owner"
	snapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "fixture-store", Entries: []contract.Entry{}}}}
	snapshotDigest, err := evidence.SnapshotDigest(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	oracle := evidence.Oracle{SchemaVersion: evidence.Version, Binding: mainBinding, PeerBinding: peerBinding,
		RequiredStores: []string{"fixture-store"}, PeerPreState: &snapshot, PeerPostState: &snapshot}
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		oracle.Domains = append(oracle.Domains, contract.DomainEvidence{Domain: domain, Before: snapshot, After: snapshot, Allowlist: []contract.Change{}})
	}
	oracle.PeerReceipts = forgedReceipts(t, peerBinding, snapshotDigest)
	oracleBytes, err := json.Marshal(oracle)
	if err != nil {
		t.Fatal(err)
	}
	createJournal(t, mainBinding)
	createJournal(t, peerBinding)
	if err := os.Mkdir(filepath.Join(mainRoot, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mainRoot, "evidence", oracleName), oracleBytes, 0600); err != nil {
		t.Fatal(err)
	}
	mainJournal, err := lifecycle.Open(mainRoot, mainBinding)
	if err != nil {
		t.Fatal(err)
	}
	if err := recordPassingReceipts(mainJournal, snapshotDigest, contract.PayloadDigest(oracleBytes)); err != nil {
		t.Fatal(err)
	}
	if err := mainJournal.Close(); err != nil {
		t.Fatal(err)
	}
	result, err := Verify(mainRoot, mainBinding.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if result.Verdict == contract.Pass || result.Reason != "independent persisted journal receipts missing" {
		t.Fatalf("oracle-supplied peer receipts were trusted over empty journal: %+v", result)
	}
}

func TestVerifyRejectsPeerWorkspaceOutsideMainBinding(t *testing.T) {
	mainRoot := t.TempDir()
	peerRoot := t.TempDir()
	mainBinding := testBinding(mainRoot, "peer-path-main")
	peerBinding := testBinding(peerRoot, "peer-path-run")
	peerBinding.OwnershipMarker = "independent-owner"
	oracleBytes, err := json.Marshal(evidence.Oracle{SchemaVersion: evidence.Version, Binding: mainBinding, PeerBinding: peerBinding})
	if err != nil {
		t.Fatal(err)
	}
	createJournal(t, mainBinding)
	writeOracleAndVerifyReceipt(t, mainRoot, mainBinding, oracleBytes)
	if _, err := Verify(mainRoot, mainBinding.RunID); err == nil || !strings.Contains(err.Error(), "peer workspace is not independently bound") {
		t.Fatalf("unbound peer path accepted: %v", err)
	}
}

func TestLoadRejectsStaleJournalRevisionWithoutRepair(t *testing.T) {
	root := t.TempDir()
	binding := testBinding(root, "stale-run")
	createJournal(t, binding)
	path := filepath.Join(root, "lifecycle.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var journal map[string]any
	if err := json.Unmarshal(raw, &journal); err != nil {
		t.Fatal(err)
	}
	journal["revision"] = strings.Repeat("0", 64)
	stale, err := json.Marshal(journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, stale, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(root, binding.RunID); err == nil {
		t.Fatal("stale lifecycle revision accepted")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(stale, after) {
		t.Fatalf("stale journal was modified: %v", err)
	}
}

func TestEvidenceReadsRejectSymlinkAndWritesDoNotFollowIt(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	external := filepath.Join(t.TempDir(), "outside.json")
	if err := os.WriteFile(external, []byte("sentinel"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, filepath.Join(root, "evidence", oracleName)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, filepath.Join(root, "evidence", verificationName)); err != nil {
		t.Fatal(err)
	}
	if _, err := readOwnedFile(root, filepath.Join(root, "evidence", oracleName)); err == nil {
		t.Fatal("symlinked oracle accepted")
	}
	if err := WriteVerification(root, evidence.Result{SchemaVersion: evidence.Version, Verdict: contract.Inconclusive, Qualification: "pending"}); err == nil {
		t.Fatal("writer replaced a symlink output")
	}
	contents, err := os.ReadFile(external)
	if err != nil || string(contents) != "sentinel" {
		t.Fatalf("external symlink target changed: %q, %v", contents, err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "evidence"))
	if err != nil || len(entries) != 2 {
		t.Fatalf("temporary evidence file leaked after refusal: %v, %v", entries, err)
	}
}

func TestOracleReadEnforcesFileSizeBound(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(filepath.Join(root, "evidence", oracleName), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxFileSize + 1); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := readOwnedFile(root, filepath.Join(root, "evidence", oracleName)); err == nil {
		t.Fatal("oversized oracle accepted")
	}
}

func TestVerificationWriterRejectsUnsafeDirectoryBeforeOutput(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "evidence")); err != nil {
		t.Fatal(err)
	}
	err := WriteVerification(root, evidence.Result{SchemaVersion: evidence.Version, Verdict: contract.Inconclusive, Qualification: "pending"})
	if err == nil {
		t.Fatal("symlink evidence directory accepted")
	}
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatalf("writer created output outside run evidence: %v, %v", entries, err)
	}
}

func TestMultiFileEvidenceWriteValidatesAllTargetsBeforeWriting(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "evidence", reportMDName), 0700); err != nil {
		t.Fatal(err)
	}
	err := writeEvidenceFiles(root, map[string][]byte{reportJSONName: []byte("new report"), reportMDName: []byte("new markdown")})
	if err == nil {
		t.Fatal("directory target unexpectedly accepted")
	}
	if _, err := os.Lstat(filepath.Join(root, "evidence", reportJSONName)); !os.IsNotExist(err) {
		t.Fatalf("partial report JSON was written before target refusal: %v", err)
	}
	entries, err := os.ReadDir(filepath.Join(root, "evidence"))
	if err != nil || len(entries) != 1 || entries[0].Name() != reportMDName {
		t.Fatalf("staged temporary file leaked: %v, %v", entries, err)
	}
}

func TestWriteReportUsesPersistedRunsAndStoresOnlyRedactedSummaries(t *testing.T) {
	mainRoot := t.TempDir()
	peerRoot := filepath.Join(mainRoot, "peer-run")
	mainBinding := testBinding(mainRoot, "report-main")
	mainBinding.Paths["peer_workspace"] = peerRoot
	peerBinding := testBinding(peerRoot, "report-peer")
	peerBinding.OwnershipMarker = "independent-owner"
	oracle := evidence.Oracle{SchemaVersion: evidence.Version, Binding: mainBinding, PeerBinding: peerBinding, RequiredStores: []string{"private-token-value"},
		Receipts: []contract.Receipt{{RunID: "forged", State: contract.Succeeded}}, PeerReceipts: []contract.Receipt{{RunID: "forged", State: contract.Succeeded}}}
	oracleBytes, err := json.Marshal(oracle)
	if err != nil {
		t.Fatal(err)
	}
	createJournal(t, mainBinding)
	createJournal(t, peerBinding)
	if err := os.Mkdir(filepath.Join(mainRoot, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mainRoot, "evidence", oracleName), oracleBytes, 0600); err != nil {
		t.Fatal(err)
	}
	mainJournal, err := lifecycle.Open(mainRoot, mainBinding)
	if err != nil {
		t.Fatal(err)
	}
	digest := contract.PayloadDigest(oracleBytes)
	if err := mainJournal.RecordIntent("verify", contract.Receipt{Phase: contract.Verify}); err != nil {
		t.Fatal(err)
	}
	if err := mainJournal.RecordResult(contract.Receipt{Phase: contract.Verify, State: contract.Succeeded, EvidenceDigests: map[string]string{"oracle": digest}}); err != nil {
		t.Fatal(err)
	}
	if err := mainJournal.Close(); err != nil {
		t.Fatal(err)
	}
	result, err := WriteReport(mainRoot, mainBinding.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if result.Verdict == contract.Pass || result.Qualification == "runtime_qualified" {
		t.Fatalf("incomplete local evidence was qualified: %+v", result)
	}
	for _, name := range []string{reportJSONName, reportMDName} {
		contents, err := os.ReadFile(filepath.Join(mainRoot, "evidence", name))
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(contents, []byte("private-token-value")) || bytes.Contains(contents, []byte(mainRoot)) || bytes.Contains(contents, []byte(peerRoot)) {
			t.Fatalf("report leaked private oracle data or local paths in %s", name)
		}
	}
}

func createJournal(t *testing.T, binding contract.RunBinding) {
	t.Helper()
	journal, err := lifecycle.Open(binding.Workspace, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
}

func writeOracleAndVerifyReceipt(t *testing.T, root string, binding contract.RunBinding, oracle []byte) {
	t.Helper()
	if err := os.Mkdir(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "evidence", oracleName), oracle, 0600); err != nil {
		t.Fatal(err)
	}
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("verify", contract.Receipt{Phase: contract.Verify}); err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordResult(contract.Receipt{Phase: contract.Verify, State: contract.Succeeded, EvidenceDigests: map[string]string{"oracle": contract.PayloadDigest(oracle)}}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
}

func recordPassingReceipts(journal *lifecycle.Lifecycle, snapshotDigest, oracleDigest string) error {
	for _, item := range []struct {
		phase     contract.Phase
		operation string
		digests   map[string]string
	}{{contract.Capture, "capture", map[string]string{"capture": snapshotDigest}},
		{contract.Stage, "init", map[string]string{"stage": snapshotDigest}},
		{contract.Run, "run", map[string]string{"run": snapshotDigest}},
		{contract.Verify, "verify", map[string]string{"oracle": oracleDigest,
			"topology.before": snapshotDigest, "topology.after": snapshotDigest,
			"migration.before": snapshotDigest, "migration.after": snapshotDigest,
			"block.before": snapshotDigest, "block.after": snapshotDigest}}} {
		if err := journal.RecordIntent(item.operation, contract.Receipt{Phase: item.phase}); err != nil {
			return err
		}
		if err := journal.RecordResult(contract.Receipt{Phase: item.phase, State: contract.Succeeded, EvidenceDigests: item.digests}); err != nil {
			return err
		}
	}
	return nil
}

func forgedReceipts(t *testing.T, binding contract.RunBinding, snapshotDigest string) []contract.Receipt {
	t.Helper()
	bindingDigest, err := contract.Digest(binding)
	if err != nil {
		t.Fatal(err)
	}
	var receipts []contract.Receipt
	sequence := uint64(1)
	predecessor := ""
	for _, item := range []struct {
		phase     contract.Phase
		operation string
		digests   map[string]string
	}{{contract.Capture, "capture", map[string]string{"capture": snapshotDigest}},
		{contract.Stage, "init", map[string]string{"stage": snapshotDigest}},
		{contract.Run, "run", map[string]string{"run": snapshotDigest}},
		{contract.Verify, "verify", map[string]string{"migration.before": snapshotDigest, "migration.after": snapshotDigest}}} {
		intent := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: bindingDigest,
			Phase: item.phase, Operation: item.operation, State: contract.Running, Sequence: sequence, Predecessor: predecessor,
			EvidenceDigests: map[string]string{}}
		receipts = append(receipts, intent)
		intentDigest, err := contract.Digest(intent)
		if err != nil {
			t.Fatal(err)
		}
		result := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: bindingDigest,
			Phase: item.phase, Operation: item.operation, State: contract.Succeeded, Sequence: sequence + 1, Predecessor: intentDigest,
			EvidenceDigests: item.digests}
		receipts = append(receipts, result)
		predecessor, err = contract.Digest(result)
		if err != nil {
			t.Fatal(err)
		}
		sequence += 2
	}
	return receipts
}

func testBinding(root, runID string) contract.RunBinding {
	height := int64(2)
	return contract.RunBinding{SchemaVersion: contract.Version, RunID: runID, Scenario: contract.Scenario,
		Workspace: root, OwnershipMarker: "test-owner", ChainID: "fixture-chain", GenesisSHA256: strings.Repeat("a", 64),
		Heights: contract.Heights{Blockstore: 3, App: 2, Consensus: &height, FirstRepaired: 4}, BlockID: "block-3", AppHash: "app-2", AppHashHeight: 2,
		ToolVersion: "test", CatalogVersion: "fixture", InputDigests: map[string]string{"source_manifest": strings.Repeat("b", 64)},
		RuntimeIdentities: map[string]string{"standard": "sha256:fixture"}, Paths: map[string]string{}}
}
