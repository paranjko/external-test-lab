package capture

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestOfflinePreflightReportsUnavailableIncidentProofs(t *testing.T) {
	r := OfflinePreflight(contract.RunBinding{}, contract.SourceManifest{}, nil, Policy{}, PreflightEvidence{}, Capacity{})
	if r.InputsComplete || r.CaptureAuthorized || r.Status != "BLOCKED" || r.Qualification != "not_evaluated" {
		t.Fatalf("unsafe preflight result: %#v", r)
	}
	required := map[string]bool{"source_manifest_unavailable": false, "layout_proof_missing": false, "witnesses_missing": false, "offline_reader_missing": false, "consensus_height_unknown": false, "workspace_capacity_unknown": false, "capture_capacity_unknown": false, "cpu_capacity_insufficient": false, "memory_capacity_insufficient": false}
	for _, d := range r.Diagnostics {
		if _, ok := required[d.Code]; ok {
			required[d.Code] = true
		}
	}
	for code, found := range required {
		if !found {
			t.Errorf("missing diagnostic %s: %#v", code, r.Diagnostics)
		}
	}
}

func TestOfflinePreflightComputesSizingButNeverAuthorizes(t *testing.T) {
	b := contract.RunBinding{SchemaVersion: contract.Version, RunID: "offline-run", Scenario: contract.Scenario, Workspace: "/tmp/preflight-workspace", OwnershipMarker: "owner", ChainID: "chain", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 10, App: 9, Consensus: int64ptr(10), FirstRepaired: 11}, BlockID: "block-10", AppHash: "app-9", AppHashHeight: 9, ToolVersion: "fixture", CatalogVersion: "fixture", RuntimeIdentities: map[string]string{"runtime": strings.Repeat("b", 64)}, Paths: map[string]string{"source": "/tmp/preflight-workspace/offline-run/source", "export": "/tmp/preflight-workspace/offline-run/export"}}
	body := []byte("offline synthetic snapshot")
	sum := sha256.Sum256(body)
	m := contract.SourceManifest{SignedMetadata: contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "source_manifest", Scope: "capture", KeyID: "fixture", RunID: b.RunID, ChainID: b.ChainID, GenesisSHA256: b.GenesisSHA256, IssuedAt: time.Now().UTC().Add(-time.Minute), ExpiresAt: time.Now().UTC().Add(time.Hour)}, SnapshotID: "snapshot-fixture", Checkpoint: "atomic-fixture", Backend: "goleveldb", Layout: "fixture-layout", BackendVersion: "v1", Frozen: true, Heights: b.Heights, Components: []string{"blockstore"}, Files: []contract.ExportFile{{Path: "blockstore/data.db", SHA256: hex.EncodeToString(sum[:]), Size: int64(len(body))}}}
	m.BindingDigest, _ = contract.InputBindingDigest(b)
	payload, _ := json.Marshal(m)
	b.InputDigests = map[string]string{"source_manifest": contract.PayloadDigest(payload)}
	p := Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{"blockstore/data.db"}, Backend: m.Backend, Layout: m.Layout, BackendVersion: m.BackendVersion, MaxBytes: 1024, ReserveBytes: 32}
	ref := func(name string) EvidenceReference {
		return EvidenceReference{Available: true, Reference: name, SHA256: strings.Repeat("c", 64)}
	}
	e := PreflightEvidence{Freeze: ref("freeze"), Layout: LayoutEvidence{EvidenceReference: ref("layout"), Backend: m.Backend, Layout: m.Layout, Version: m.BackendVersion, SnapshotID: m.SnapshotID}, Inventory: ref("inventory"), CaptureApproval: ref("approval"), Witnesses: []WitnessInput{{EvidenceReference: ref("witness-a"), Identity: "node-a", BlockID: b.BlockID, BlockHeight: 10, AppHash: b.AppHash, AppHashHeight: 9}, {EvidenceReference: ref("witness-b"), Identity: "node-b", BlockID: b.BlockID, BlockHeight: 10, AppHash: b.AppHash, AppHashHeight: 9}}, OfflineReader: OfflineReaderInput{EvidenceReference: ref("offline-reader"), ConsensusHeight: int64ptr(10)}}
	exportBytes := int64(len(body))
	required := exportBytes*5 + minimumDiskReserve
	r := OfflinePreflight(b, m, payload, p, e, Capacity{CPUs: minimumCPUs, RAMBytes: minimumRAM, WorkspaceAvailableBytes: required, CaptureAvailableBytes: exportBytes + 32})
	if !r.InputsComplete || r.CaptureAuthorized || r.Status != "INPUTS_PRESENT_UNVERIFIED" || r.Qualification != "not_evaluated" {
		t.Fatalf("unexpected report: %#v", r)
	}
	if r.ExportBytes != exportBytes || r.RequiredWorkspaceBytes != required || r.RequiredCaptureBytes != exportBytes+32 {
		t.Fatalf("capacity policy mismatch: %#v", r)
	}
	if len(r.Unverified) < 4 {
		t.Fatalf("proofs were treated as verified: %#v", r.Unverified)
	}
}

func TestOfflinePreflightBlocksWitnessMismatchAndInsufficientCapacity(t *testing.T) {
	b, m, p, payload, e := completePreflightFixture(t)
	e.Witnesses[1].Identity = e.Witnesses[0].Identity
	e.Witnesses[1].BlockID = "different"
	r := OfflinePreflight(b, m, payload, p, e, Capacity{CPUs: minimumCPUs - 1, RAMBytes: minimumRAM - 1, WorkspaceAvailableBytes: 1, CaptureAvailableBytes: 1})
	codes := map[string]bool{}
	for _, d := range r.Diagnostics {
		codes[d.Code] = true
	}
	for _, code := range []string{"witness_identity_duplicate", "witness_binding_mismatch", "cpu_capacity_insufficient", "memory_capacity_insufficient", "workspace_capacity_insufficient", "capture_capacity_insufficient"} {
		if !codes[code] {
			t.Errorf("missing %s: %#v", code, r.Diagnostics)
		}
	}
	if r.CaptureAuthorized || r.InputsComplete {
		t.Fatal("mismatched witness/capacity passed")
	}
}

func TestInventoryBytesDetectsOverflow(t *testing.T) {
	if _, err := inventoryBytes([]contract.ExportFile{{Path: "a", Size: int64(^uint64(0) >> 1)}, {Path: "b", Size: 1}}); err == nil {
		t.Fatal("inventory size overflow accepted")
	}
}

func completePreflightFixture(t *testing.T) (contract.RunBinding, contract.SourceManifest, Policy, []byte, PreflightEvidence) {
	t.Helper()
	b := contract.RunBinding{SchemaVersion: contract.Version, RunID: "fixture-run", Scenario: contract.Scenario, Workspace: "/tmp/fixture-workspace", OwnershipMarker: "owner", ChainID: "chain", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 2, App: 1, Consensus: int64ptr(2), FirstRepaired: 3}, BlockID: "b2", AppHash: "a1", AppHashHeight: 1, ToolVersion: "v", CatalogVersion: "c", RuntimeIdentities: map[string]string{"runtime": "fixture"}, Paths: map[string]string{"source": "/tmp/fixture-workspace/source", "export": "/tmp/fixture-workspace/export"}}
	m := contract.SourceManifest{SignedMetadata: contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "source_manifest", Scope: "capture", RunID: b.RunID, ChainID: b.ChainID, GenesisSHA256: b.GenesisSHA256}, SnapshotID: "snapshot", Checkpoint: "checkpoint", Backend: "fixture", Layout: "flat", BackendVersion: "1", Frozen: true, Heights: b.Heights, Components: []string{"blockstore"}, Files: []contract.ExportFile{{Path: "db", SHA256: strings.Repeat("c", 64), Size: 2}}}
	m.BindingDigest, _ = contract.InputBindingDigest(b)
	payload, _ := json.Marshal(m)
	b.InputDigests = map[string]string{"source_manifest": contract.PayloadDigest(payload)}
	p := Policy{AllowedComponents: []string{"blockstore"}, AllowedFiles: []string{"db"}, Backend: m.Backend, Layout: m.Layout, BackendVersion: m.BackendVersion, MaxBytes: 10}
	ref := func(n string) EvidenceReference {
		return EvidenceReference{Available: true, Reference: n, SHA256: strings.Repeat("d", 64)}
	}
	e := PreflightEvidence{Freeze: ref("freeze"), Layout: LayoutEvidence{EvidenceReference: ref("layout"), Backend: m.Backend, Layout: m.Layout, Version: m.BackendVersion, SnapshotID: m.SnapshotID}, Inventory: ref("inventory"), CaptureApproval: ref("approval"), Witnesses: []WitnessInput{{EvidenceReference: ref("w1"), Identity: "1", BlockID: b.BlockID, BlockHeight: 2, AppHash: b.AppHash, AppHashHeight: 1}, {EvidenceReference: ref("w2"), Identity: "2", BlockID: b.BlockID, BlockHeight: 2, AppHash: b.AppHash, AppHashHeight: 1}}, OfflineReader: OfflineReaderInput{EvidenceReference: ref("reader"), ConsensusHeight: int64ptr(2)}}
	return b, m, p, payload, e
}
