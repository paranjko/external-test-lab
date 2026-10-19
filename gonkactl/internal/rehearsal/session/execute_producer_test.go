//go:build linux

package session

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

func TestExecuteProducerGateAllowsRealCometEvidenceForStageAndRun(t *testing.T) {
	f := newProducerPhaseFixture(t, false)
	stage := &producerStageAdapter{after: f.snapshot}
	if receipt, err := ExecuteStage(context.Background(), f.main.Workspace, f.main.RunID, stage); err != nil || receipt.State != contract.Succeeded || !stage.called {
		t.Fatalf("verified producer evidence did not allow Stage: receipt=%+v err=%v adapter=%+v", receipt, err, stage)
	}
	run := &producerRunAdapter{out: RunSnapshots{MigrationBefore: f.snapshot, MigrationAfter: f.snapshot, BlockBefore: f.snapshot, BlockAfter: f.snapshot}}
	if receipt, err := ExecuteRun(context.Background(), f.main.Workspace, f.main.RunID, run); err != nil || receipt.State != contract.Succeeded || !run.called {
		t.Fatalf("verified producer evidence did not allow Run: receipt=%+v err=%v adapter=%+v", receipt, err, run)
	}
}

func TestExecuteProducerGateRejectsMissingSubstitutedAndWrongHeightBeforeStage(t *testing.T) {
	tests := []struct {
		name   string
		setup  func(*testing.T, producerPhaseFixture)
		wrongH bool
	}{
		{name: "missing", setup: func(t *testing.T, f producerPhaseFixture) {
			if err := os.Remove(filepath.Join(f.main.Workspace, "evidence", "producer-manifest.json")); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "substitution", setup: func(t *testing.T, f producerPhaseFixture) {
			path := filepath.Join(f.main.Workspace, "evidence", "block-h.bin")
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			raw[len(raw)-1] ^= 1
			write0600(t, path, raw)
		}},
		{name: "wrong-height", wrongH: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := newProducerPhaseFixture(t, tt.wrongH)
			if tt.setup != nil {
				tt.setup(t, f)
			}
			path := filepath.Join(f.main.Workspace, "lifecycle.json")
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			stage := &producerStageAdapter{after: f.snapshot}
			if _, err := ExecuteStage(context.Background(), f.main.Workspace, f.main.RunID, stage); err == nil {
				t.Fatal("invalid producer evidence accepted")
			}
			if stage.preflight || stage.called {
				t.Fatalf("adapter called before producer rejection: %+v", stage)
			}
			after, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(before, after) {
				t.Fatalf("producer rejection changed journal: %v", err)
			}
			_, state, _, receipts, err := lifecycle.ReadStoredSnapshot(f.main.Workspace)
			if err != nil || state != contract.Running || len(receipts) != 2 {
				t.Fatalf("producer rejection changed lifecycle: state=%s receipts=%d err=%v", state, len(receipts), err)
			}
		})
	}
}

func TestExecuteProducerGateRevalidatesAfterPreflightBeforeIntent(t *testing.T) {
	f := newProducerPhaseFixture(t, false)
	journalPath := filepath.Join(f.main.Workspace, "lifecycle.json")
	before, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	blockPath := filepath.Join(f.main.Workspace, "evidence", "block-h.bin")
	stage := &producerStageAdapter{after: f.snapshot, preflightFn: func() {
		raw, err := os.ReadFile(blockPath)
		if err != nil {
			t.Fatal(err)
		}
		raw[len(raw)-1] ^= 1
		write0600(t, blockPath, raw)
	}}
	if _, err := ExecuteStage(context.Background(), f.main.Workspace, f.main.RunID, stage); !errors.Is(err, ErrPhasePrecondition) {
		t.Fatalf("preflight evidence substitution was not refused before intent: %v", err)
	}
	if !stage.preflight || stage.called {
		t.Fatalf("unexpected adapter calls: %+v", stage)
	}
	after, err := os.ReadFile(journalPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("preflight substitution wrote journal intent: %v", err)
	}
}

func TestExecuteRunProducerGateRejectsSubstitutionBeforePreflight(t *testing.T) {
	f := newProducerPhaseFixture(t, false)
	stage := &producerStageAdapter{after: f.snapshot}
	if _, err := ExecuteStage(context.Background(), f.main.Workspace, f.main.RunID, stage); err != nil {
		t.Fatal(err)
	}
	journalPath := filepath.Join(f.main.Workspace, "lifecycle.json")
	before, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	blockPath := filepath.Join(f.main.Workspace, "evidence", "block-h.bin")
	raw, err := os.ReadFile(blockPath)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-1] ^= 1
	write0600(t, blockPath, raw)
	run := &producerRunAdapter{out: RunSnapshots{MigrationBefore: f.snapshot, MigrationAfter: f.snapshot, BlockBefore: f.snapshot, BlockAfter: f.snapshot}}
	if _, err := ExecuteRun(context.Background(), f.main.Workspace, f.main.RunID, run); err == nil {
		t.Fatal("Run accepted substituted producer evidence")
	}
	if run.preflight || run.called {
		t.Fatalf("Run adapter called before producer rejection: %+v", run)
	}
	after, err := os.ReadFile(journalPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("Run producer rejection changed journal: %v", err)
	}
}

type producerPhaseFixture struct {
	main     contract.RunBinding
	snapshot contract.Snapshot
}

func newProducerPhaseFixture(t *testing.T, wrongHeight bool) producerPhaseFixture {
	t.Helper()
	base := t.TempDir()
	mainRoot, peerRoot := filepath.Join(base, "main"), filepath.Join(base, "peer-not-yet-captured")
	comet := makeSessionCometEvidence(t)
	if wrongHeight {
		comet.want.Height++
		comet.want.BlockstoreHeight++
		comet.want.ValidatorSetHeight++
	}
	height := comet.want.Height
	main := freshBinding(mainRoot, "phase-producer-main", "owner-main", height)
	main.ChainID = comet.want.ChainID
	main.Heights.Blockstore, main.Heights.App, main.Heights.FirstRepaired = height, height-1, height
	main.Heights.Consensus = int64Pointer(height - 1)
	main.AppHashHeight = height - 1
	main.BlockID, main.AppHash = comet.want.BlockID, comet.want.HeaderAppHash
	main.InputDigests["recovery-binary"] = strings.Repeat("b", 64)
	main.InputDigests["producer-binary"] = strings.Repeat("e", 64)
	main.Paths["peer_workspace"] = peerRoot
	mainFiles := pinSessionProducerEvidence(t, main, comet)
	if err := contract.ValidateBinding(main); err != nil {
		t.Fatal(err)
	}
	createJournal(t, main)
	snapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "auth", Entries: []contract.Entry{}}}}
	writeSnapshots(t, mainRoot, map[string]contract.Snapshot{"topology.before": snapshot})
	seedCaptureReceipt(t, main, snapshot)
	writeSessionProducerEvidence(t, mainRoot, mainFiles)
	return producerPhaseFixture{main: main, snapshot: snapshot}
}

type producerStageAdapter struct {
	after       contract.Snapshot
	preflightFn func()
	preflight   bool
	called      bool
}

func (a *producerStageAdapter) Preflight(context.Context, contract.RunBinding) error {
	a.preflight = true
	if a.preflightFn != nil {
		a.preflightFn()
	}
	return nil
}
func (a *producerStageAdapter) ExecuteStage(context.Context, contract.RunBinding) (contract.Snapshot, error) {
	a.called = true
	return a.after, nil
}

type producerRunAdapter struct {
	out       RunSnapshots
	preflight bool
	called    bool
}

func (a *producerRunAdapter) Preflight(context.Context, contract.RunBinding) error {
	a.preflight = true
	return nil
}
func (a *producerRunAdapter) ExecuteRun(context.Context, contract.RunBinding) (RunSnapshots, error) {
	a.called = true
	return a.out, nil
}
