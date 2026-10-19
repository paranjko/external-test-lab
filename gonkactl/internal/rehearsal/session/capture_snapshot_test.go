//go:build linux

package session

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

type snapshotReaderFunc func(context.Context, contract.RunBinding) (contract.Snapshot, error)

func (f snapshotReaderFunc) ReadSnapshot(ctx context.Context, binding contract.RunBinding) (contract.Snapshot, error) {
	return f(ctx, binding)
}

type captureAdapterFunc func(context.Context, contract.RunBinding, contract.SourceManifest) (contract.Receipt, error)

func (f captureAdapterFunc) Capture(ctx context.Context, binding contract.RunBinding, manifest contract.SourceManifest) (contract.Receipt, error) {
	return f(ctx, binding, manifest)
}

func TestCapturePersistsBoundLogicalSnapshotBeforeSuccessReceipt(t *testing.T) {
	workspace, binding, manifest := snapshotFixture(t)
	journal, err := lifecycle.Open(workspace, binding)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	if err := installSnapshotSource(binding, []byte("copied db bytes")); err != nil {
		t.Fatal(err)
	}
	snapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "store-a", Entries: []contract.Entry{{Key: []byte("key"), Value: []byte("value")}}}}}
	reader := snapshotReaderFunc(func(_ context.Context, got contract.RunBinding) (contract.Snapshot, error) {
		if got.Paths["source"] != binding.Paths["source"] {
			t.Fatal("reader did not receive bound source path")
		}
		// Mutating a reader's binding copy must not alter the immutable caller binding.
		got.Paths["source"] = filepath.Join(workspace, "attacker")
		return snapshot, nil
	})
	adapter := captureMutationAdapter{adapter: captureAdapterFunc(func(_ context.Context, _ contract.RunBinding, _ contract.SourceManifest) (contract.Receipt, error) {
		return contract.Receipt{Phase: contract.Capture, State: contract.Succeeded}, nil
	}), manifest: manifest, snapshotReader: reader}
	receipt, err := journal.Execute(context.Background(), "frozen_export_copy", contract.Receipt{Phase: contract.Capture}, adapter)
	if err != nil || receipt.State != contract.Succeeded {
		t.Fatalf("receipt=%+v err=%v", receipt, err)
	}
	wantDigest, err := evidence.SnapshotDigest(snapshot)
	if err != nil || receipt.EvidenceDigests["topology.before"] != wantDigest {
		t.Fatalf("topology digest=%q want=%q err=%v", receipt.EvidenceDigests["topology.before"], wantDigest, err)
	}
	raw, err := os.ReadFile(filepath.Join(workspace, "evidence", topologyBeforeSnapshotFile))
	if err != nil {
		t.Fatal(err)
	}
	var stored contract.Snapshot
	if err := json.Unmarshal(raw, &stored); err != nil {
		t.Fatal(err)
	}
	storedDigest, err := evidence.SnapshotDigest(stored)
	if err != nil || storedDigest != wantDigest {
		t.Fatalf("persisted topology snapshot digest=%q want=%q err=%v", storedDigest, wantDigest, err)
	}
}

func TestSnapshotReaderFailureLeavesCaptureUnknown(t *testing.T) {
	workspace, binding, manifest := snapshotFixture(t)
	journal, err := lifecycle.Open(workspace, binding)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	if err := installSnapshotSource(binding, []byte("copied db bytes")); err != nil {
		t.Fatal(err)
	}
	adapter := captureMutationAdapter{adapter: captureAdapterFunc(func(_ context.Context, _ contract.RunBinding, _ contract.SourceManifest) (contract.Receipt, error) {
		return contract.Receipt{Phase: contract.Capture, State: contract.Succeeded}, nil
	}), manifest: manifest, snapshotReader: snapshotReaderFunc(func(context.Context, contract.RunBinding) (contract.Snapshot, error) {
		return contract.Snapshot{}, errors.New("synthetic reader failure")
	})}
	receipt, err := journal.Execute(context.Background(), "frozen_export_copy", contract.Receipt{Phase: contract.Capture}, adapter)
	if err == nil || receipt.State != contract.Unknown {
		t.Fatalf("reader error was not journaled as unknown: receipt=%+v err=%v", receipt, err)
	}
	_, state, _, receipts := journal.Snapshot()
	if state != contract.Unknown || len(receipts) != 2 || receipts[len(receipts)-1].State != contract.Unknown {
		t.Fatalf("journal did not preserve unknown capture outcome: state=%s receipts=%+v", state, receipts)
	}
	if _, err := os.Stat(filepath.Join(workspace, "evidence", topologyBeforeSnapshotFile)); !os.IsNotExist(err) {
		t.Fatalf("failed snapshot unexpectedly persisted: %v", err)
	}
}

func TestSnapshotRejectsDuplicateStoresAndSourceReplacement(t *testing.T) {
	for _, tc := range []struct {
		name   string
		reader func(string) SnapshotReader
	}{
		{name: "duplicate store", reader: func(_ string) SnapshotReader {
			return snapshotReaderFunc(func(context.Context, contract.RunBinding) (contract.Snapshot, error) {
				store := contract.LogicalStore{Name: "duplicate"}
				return contract.Snapshot{Stores: []contract.LogicalStore{store, store}}, nil
			})
		}},
		{name: "source content mutation", reader: func(source string) SnapshotReader {
			return snapshotReaderFunc(func(_ context.Context, _ contract.RunBinding) (contract.Snapshot, error) {
				if err := os.WriteFile(filepath.Join(source, "block.db"), []byte("tampered"), 0600); err != nil {
					return contract.Snapshot{}, err
				}
				return validSnapshot(), nil
			})
		}},
		{name: "source root replacement", reader: func(source string) SnapshotReader {
			return snapshotReaderFunc(func(_ context.Context, _ contract.RunBinding) (contract.Snapshot, error) {
				if err := os.Rename(source, source+".old"); err != nil {
					return contract.Snapshot{}, err
				}
				if err := os.Mkdir(source, 0700); err != nil {
					return contract.Snapshot{}, err
				}
				if err := os.WriteFile(filepath.Join(source, "block.db"), []byte("tampered"), 0600); err != nil {
					return contract.Snapshot{}, err
				}
				return validSnapshot(), nil
			})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			workspace, binding, manifest := snapshotFixture(t)
			if err := os.MkdirAll(workspace, 0700); err != nil {
				t.Fatal(err)
			}
			if err := installSnapshotSource(binding, []byte("copied db bytes")); err != nil {
				t.Fatal(err)
			}
			_, err := captureTopologySnapshot(context.Background(), binding, manifest, tc.reader(binding.Paths["source"]))
			if err == nil {
				t.Fatal("invalid logical snapshot/source mutation accepted")
			}
			if _, err := os.Stat(filepath.Join(workspace, "evidence", topologyBeforeSnapshotFile)); !os.IsNotExist(err) {
				t.Fatalf("invalid evidence was persisted: %v", err)
			}
		})
	}
}

func snapshotFixture(t *testing.T) (string, contract.RunBinding, contract.SourceManifest) {
	t.Helper()
	workspace := filepath.Join(t.TempDir(), "run")
	consensus := int64(4)
	binding := contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "snapshot-run", Scenario: contract.Scenario,
		Workspace: workspace, OwnershipMarker: "snapshot-owner", ChainID: "fixture-chain",
		GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 4, App: 3, Consensus: &consensus, FirstRepaired: 5},
		BlockID: "block-4", AppHash: "app-3", AppHashHeight: 3, ToolVersion: "test", CatalogVersion: "test",
		RuntimeIdentities: map[string]string{"runtime": "fixture"}, Paths: map[string]string{"export": filepath.Join(workspace, "export"), "source": filepath.Join(workspace, "source")},
		InputDigests: map[string]string{"source_manifest": strings.Repeat("b", 64)},
	}
	body := []byte("copied db bytes")
	sum := sha256.Sum256(body)
	manifest := contract.SourceManifest{Files: []contract.ExportFile{{Path: "block.db", SHA256: hex.EncodeToString(sum[:]), Size: int64(len(body))}}}
	if err := contract.ValidateBinding(binding); err != nil {
		t.Fatal(err)
	}
	return workspace, binding, manifest
}

func installSnapshotSource(binding contract.RunBinding, body []byte) error {
	if err := os.MkdirAll(binding.Workspace, 0700); err != nil {
		return err
	}
	if err := os.Mkdir(binding.Paths["source"], 0700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(binding.Paths["source"], "block.db"), body, 0600)
}

func validSnapshot() contract.Snapshot {
	return contract.Snapshot{Stores: []contract.LogicalStore{{Name: "store", Entries: []contract.Entry{{Key: []byte("key"), Value: []byte("value")}}}}}
}
