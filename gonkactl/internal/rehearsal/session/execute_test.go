//go:build linux

package session

import (
	"context"
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

func TestExecuteStageAndRunJournalSnapshotsInOrder(t *testing.T) {
	f := newPhaseFixture(t)
	stage := &testStageAdapter{after: phaseSnapshot("auth", "stage")}
	stageReceipt, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, stage)
	if err != nil || stageReceipt.Phase != contract.Stage || stageReceipt.State != contract.Succeeded || !contract.IsDigest(stageReceipt.EvidenceDigests["topology.after"]) {
		t.Fatalf("stage receipt=%+v err=%v", stageReceipt, err)
	}
	if !stage.preflight || !stage.called {
		t.Fatalf("stage adapter did not preflight and execute: %+v", stage)
	}
	run := &testRunAdapter{out: RunSnapshots{MigrationBefore: phaseSnapshot("auth", "stage"), MigrationAfter: phaseSnapshot("auth", "migrated"), BlockBefore: phaseSnapshot("auth", "stage"), BlockAfter: phaseSnapshot("auth", "repaired")}}
	runReceipt, err := ExecuteRun(context.Background(), f.binding.Workspace, f.binding.RunID, run)
	if err != nil || runReceipt.Phase != contract.Run || runReceipt.State != contract.Succeeded || len(runReceipt.EvidenceDigests) != 4 {
		t.Fatalf("run receipt=%+v err=%v", runReceipt, err)
	}
	if !run.preflight || !run.called {
		t.Fatalf("run adapter did not preflight and execute: %+v", run)
	}
	_, state, _, receipts, err := lifecycle.ReadStoredSnapshot(f.binding.Workspace)
	if err != nil || state != contract.Running || len(receipts) != 6 {
		t.Fatalf("unexpected phase history: state=%s receipts=%d err=%v", state, len(receipts), err)
	}
	for i, phase := range []contract.Phase{contract.Capture, contract.Stage, contract.Run} {
		if receipts[2*i].Phase != phase || receipts[2*i+1].Phase != phase || receipts[2*i].State != contract.Running || receipts[2*i+1].State != contract.Succeeded {
			t.Fatalf("phase history not ordered at %s: %+v", phase, receipts)
		}
	}
	for key, digest := range map[string]string{"topology.after": "snapshot-topology-after.json", "migration.before": "snapshot-migration-before.json", "migration.after": "snapshot-migration-after.json", "block.before": "snapshot-block-before.json", "block.after": "snapshot-block-after.json"} {
		snapshot, err := readSnapshotFile(f.binding.Workspace, key)
		if err != nil {
			t.Fatalf("read %s: %v", key, err)
		}
		if _, err := evidence.SnapshotDigest(snapshot); err != nil {
			t.Fatalf("invalid persisted %s: %v", key, err)
		}
		info, err := os.Stat(filepath.Join(f.binding.Workspace, "evidence", digest))
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("snapshot file mode for %s: %v", key, err)
		}
	}
}

func TestExecuteRefusesMissingPredecessorNilAndPreflightFailureWithoutIntent(t *testing.T) {
	f := newPhaseFixture(t)
	before, err := os.ReadFile(filepath.Join(f.binding.Workspace, "lifecycle.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, nil); !errors.Is(err, ErrPhaseAdapterUnavailable) {
		t.Fatalf("nil adapter error=%v", err)
	}
	run := &testRunAdapter{}
	if _, err := ExecuteRun(context.Background(), f.binding.Workspace, f.binding.RunID, run); !errors.Is(err, ErrPhasePrecondition) {
		t.Fatalf("run without Stage accepted: %v", err)
	}
	stage := &testStageAdapter{preflightErr: errors.New("unqualified candidate")}
	if _, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, stage); !errors.Is(err, ErrPhasePrecondition) {
		t.Fatalf("preflight failure error=%v", err)
	}
	if stage.called {
		t.Fatal("stage mutation called after failed preflight")
	}
	after, err := os.ReadFile(filepath.Join(f.binding.Workspace, "lifecycle.json"))
	if err != nil || string(before) != string(after) {
		t.Fatalf("precondition failures wrote journal: %v", err)
	}
}

func TestExecuteRechecksCapturedSnapshotAfterPreflight(t *testing.T) {
	f := newPhaseFixture(t)
	path := filepath.Join(f.binding.Workspace, "evidence", snapshotFileName("topology.before"))
	stage := &testStageAdapter{after: phaseSnapshot("auth", "stage"), preflightFn: func() {
		if err := os.WriteFile(path, []byte(`{"stores":[{"name":"auth","entries":[{"key":"eA==","value":"eA=="}]}]}`), 0600); err != nil {
			t.Fatal(err)
		}
	}}
	before, err := os.ReadFile(filepath.Join(f.binding.Workspace, "lifecycle.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, stage); !errors.Is(err, ErrPhasePrecondition) {
		t.Fatalf("preflight mutation accepted: %v", err)
	}
	if stage.called {
		t.Fatal("stage mutation ran after predecessor snapshot changed")
	}
	after, err := os.ReadFile(filepath.Join(f.binding.Workspace, "lifecycle.json"))
	if err != nil || string(before) != string(after) {
		t.Fatalf("preflight mutation wrote journal intent: %v", err)
	}
}

func TestExecuteInvalidOutputQuarantinesAndCannotReplay(t *testing.T) {
	f := newPhaseFixture(t)
	invalid := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "auth"}, {Name: "auth"}}}
	stage := &testStageAdapter{after: invalid}
	if _, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, stage); !errors.Is(err, ErrPhaseExecutionUnknown) {
		t.Fatalf("invalid post-mutation result not quarantined: %v", err)
	}
	if _, state, _, _, err := lifecycle.ReadStoredSnapshot(f.binding.Workspace); err != nil || state != contract.Unknown {
		t.Fatalf("journal state=%s err=%v, want unknown", state, err)
	}
	second := &testStageAdapter{after: phaseSnapshot("auth", "stage")}
	if _, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, second); err == nil {
		t.Fatal("quarantined phase was replayed")
	}
	if second.called {
		t.Fatal("adapter executed on quarantined run")
	}
}

func TestExecuteMutationCannotReplacePinnedPredecessor(t *testing.T) {
	f := newPhaseFixture(t)
	path := filepath.Join(f.binding.Workspace, "evidence", snapshotFileName("topology.before"))
	stage := &testStageAdapter{after: phaseSnapshot("auth", "stage"), mutationFn: func() {
		if err := os.WriteFile(path, mustJSON(t, phaseSnapshot("auth", "replaced during mutation")), 0600); err != nil {
			t.Fatal(err)
		}
	}}
	if receipt, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, stage); !errors.Is(err, ErrPhaseExecutionUnknown) || receipt.State != contract.Unknown {
		t.Fatalf("predecessor replacement was not quarantined: receipt=%+v err=%v", receipt, err)
	}
	if _, state, _, _, err := lifecycle.ReadStoredSnapshot(f.binding.Workspace); err != nil || state != contract.Unknown {
		t.Fatalf("journal state=%s err=%v, want unknown", state, err)
	}
}

func TestExecutePreflightCannotMutateBinding(t *testing.T) {
	f := newPhaseFixture(t)
	stage := &testStageAdapter{after: phaseSnapshot("auth", "stage"), preflightBindingFn: func(binding contract.RunBinding) {
		binding.Paths["source"] = filepath.Join(binding.Workspace, "changed")
	}}
	if _, err := ExecuteStage(context.Background(), f.binding.Workspace, f.binding.RunID, stage); !errors.Is(err, ErrPhasePrecondition) {
		t.Fatalf("binding mutation was accepted: %v", err)
	}
	if stage.called {
		t.Fatal("stage mutation ran after preflight binding mutation")
	}
}

type phaseFixture struct{ binding contract.RunBinding }

func newPhaseFixture(t *testing.T) phaseFixture {
	t.Helper()
	root := filepath.Join(t.TempDir(), "run")
	binding := testBinding(root, "phase-run")
	binding.InputDigests["catalog"] = strings.Repeat("c", 64)
	binding.InputDigests["recovery_artifact"] = strings.Repeat("d", 64)
	createJournal(t, binding)
	if err := os.Mkdir(filepath.Join(root, "evidence"), 0700); err != nil {
		t.Fatal(err)
	}
	before := phaseSnapshot("auth", "captured")
	write0600(t, filepath.Join(root, "evidence", snapshotFileName("topology.before")), mustJSON(t, before))
	digest, err := evidence.SnapshotDigest(before)
	if err != nil {
		t.Fatal(err)
	}
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("frozen_export_copy", contract.Receipt{Phase: contract.Capture}); err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordResult(contract.Receipt{Phase: contract.Capture, State: contract.Succeeded, EvidenceDigests: map[string]string{"topology.before": digest}}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	return phaseFixture{binding: binding}
}

func phaseSnapshot(store, value string) contract.Snapshot {
	return contract.Snapshot{Stores: []contract.LogicalStore{{Name: store, Entries: []contract.Entry{{Key: []byte("key"), Value: []byte(value)}}}}}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

type testStageAdapter struct {
	after              contract.Snapshot
	preflightErr       error
	preflightFn        func()
	preflightBindingFn func(contract.RunBinding)
	mutationFn         func()
	preflight          bool
	called             bool
}

func (a *testStageAdapter) Preflight(_ context.Context, binding contract.RunBinding) error {
	a.preflight = true
	if a.preflightBindingFn != nil {
		a.preflightBindingFn(binding)
	}
	if a.preflightFn != nil {
		a.preflightFn()
	}
	return a.preflightErr
}
func (a *testStageAdapter) ExecuteStage(context.Context, contract.RunBinding) (contract.Snapshot, error) {
	a.called = true
	if a.mutationFn != nil {
		a.mutationFn()
	}
	return a.after, nil
}

type testRunAdapter struct {
	out       RunSnapshots
	preflight bool
	called    bool
}

func (a *testRunAdapter) Preflight(context.Context, contract.RunBinding) error {
	a.preflight = true
	return nil
}
func (a *testRunAdapter) ExecuteRun(context.Context, contract.RunBinding) (RunSnapshots, error) {
	a.called = true
	return a.out, nil
}
