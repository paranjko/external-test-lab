package rehearsal_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

// This is a protocol fixture, not a Core migration or runtime qualification.
func TestJournalReceiptsFeedIndependentEvidenceOracle(t *testing.T) {
	parent := t.TempDir()
	height := int64(3)
	bind := func(id string) contract.RunBinding {
		return contract.RunBinding{SchemaVersion: contract.Version, RunID: id, Scenario: contract.Scenario, Workspace: filepath.Join(parent, id), OwnershipMarker: id, ChainID: "fixture", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 3, App: 2, Consensus: &height, FirstRepaired: 3}, BlockID: "block", AppHash: "app", AppHashHeight: 2, ToolVersion: "test", CatalogVersion: "fixture-only", InputDigests: map[string]string{"source_manifest": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"binary": strings.Repeat("c", 64)}}
	}
	snapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "fixture", Entries: []contract.Entry{{Key: []byte("key"), Value: []byte("value")}}}}}
	snapshotDigest, err := evidence.SnapshotDigest(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	run := func(binding contract.RunBinding) []contract.Receipt {
		journal, err := lifecycle.Open(binding.Workspace, binding)
		if err != nil {
			t.Fatal(err)
		}
		for _, phase := range []contract.Phase{contract.Capture, contract.Stage, contract.Run, contract.Verify} {
			op := string(phase)
			if phase == contract.Stage {
				op = "init"
			}
			if err := journal.RecordIntent(op, contract.Receipt{Phase: phase}); err != nil {
				t.Fatalf("%s intent: %v", phase, err)
			}
			digests := map[string]string{"fixture": snapshotDigest}
			if phase == contract.Verify {
				for _, domain := range []string{"topology", "migration", "block"} {
					digests[domain+".before"] = snapshotDigest
					digests[domain+".after"] = snapshotDigest
				}
			}
			zero := 0
			if err := journal.RecordResult(contract.Receipt{Phase: phase, State: contract.Succeeded, ExitCode: &zero, EvidenceDigests: digests}); err != nil {
				t.Fatal(err)
			}
		}
		if err := journal.Close(); err != nil {
			t.Fatal(err)
		}
		journal, err = lifecycle.Open(binding.Workspace, binding)
		if err != nil {
			t.Fatal(err)
		}
		defer journal.Close()
		_, state, _, receipts := journal.Snapshot()
		if state != contract.Running {
			t.Fatalf("unexpected state after reopen: %s", state)
		}
		return receipts
	}
	a, b := bind("run-a"), bind("run-b")
	o := evidence.Oracle{SchemaVersion: evidence.Version, Binding: a, RequiredStores: []string{"fixture"}, Receipts: run(a), PeerBinding: b, PeerPreState: &snapshot, PeerPostState: &snapshot, PeerReceipts: run(b)}
	for _, domain := range []contract.Domain{contract.Topology, contract.Migration, contract.Block} {
		o.Domains = append(o.Domains, contract.DomainEvidence{Domain: domain, Before: snapshot, After: snapshot, Allowlist: []contract.Change{}})
	}
	r := evidence.Evaluate(o)
	if r.Verdict != contract.Pass || r.Qualification != "evidence_verified" {
		t.Fatalf("journal evidence rejected: %+v", r)
	}
	o.Receipts[1].BindingDigest = strings.Repeat("d", 64)
	if evidence.Evaluate(o).Verdict == contract.Pass {
		t.Fatal("stale journal receipt accepted")
	}
}
