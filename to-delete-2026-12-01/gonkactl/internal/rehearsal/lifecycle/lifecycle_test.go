package lifecycle

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type faultOps struct {
	osFileOps
	fail       bool
	failRename bool
}

func (f *faultOps) rename(root *os.Root, old, new string) error {
	if f.failRename {
		return errors.New("simulated ENOSPC at rename")
	}
	return f.osFileOps.rename(root, old, new)
}

type cleanupMock struct {
	validateErr        error
	validated, cleaned bool
	binding            contract.RunBinding
}

type blockingMutation struct {
	started chan struct{}
	release chan struct{}
}
type mutationFunc func(context.Context, contract.RunBinding, string) (contract.Receipt, error)

func (f mutationFunc) Execute(ctx context.Context, b contract.RunBinding, op string) (contract.Receipt, error) {
	return f(ctx, b, op)
}

func (m blockingMutation) Execute(_ context.Context, b contract.RunBinding, operation string) (contract.Receipt, error) {
	close(m.started)
	<-m.release
	d, _ := contract.Digest(b)
	return contract.Receipt{SchemaVersion: contract.Version, RunID: b.RunID, BindingDigest: d, Phase: contract.Stage, Operation: operation, State: contract.Succeeded}, nil
}

func (m *cleanupMock) ValidateOwnership(_ context.Context, b contract.RunBinding) error {
	m.validated = true
	m.binding = b
	return m.validateErr
}
func (m *cleanupMock) Cleanup(_ context.Context, b contract.RunBinding) (contract.Receipt, error) {
	m.cleaned = true
	d, _ := contract.Digest(b)
	return contract.Receipt{SchemaVersion: contract.Version, RunID: b.RunID, BindingDigest: d, Phase: contract.Cleanup, State: contract.Succeeded}, nil
}

func (f *faultOps) beforePersist() error {
	if f.fail {
		return errors.New("ENOSPC")
	}
	return nil
}

func binding(root string) contract.RunBinding {
	return contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "run-1", Scenario: contract.Scenario, Workspace: root,
		OwnershipMarker: "owner-run-1", ChainID: "local-test-chain", GenesisSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Heights: contract.Heights{Blockstore: 10, App: 9, FirstRepaired: 10}, BlockID: "block-10", AppHash: "app-hash", AppHashHeight: 9,
		ToolVersion: "test", CatalogVersion: "catalog-1", InputDigests: map[string]string{"export": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, RuntimeIdentities: map[string]string{"engine": "fixture"}, Paths: map[string]string{},
	}
}

func TestExclusiveLockAndImmutableBinding(t *testing.T) {
	root := filepath.Join(t.TempDir(), "run")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open(root, binding(root)); err == nil {
		t.Fatal("concurrent run lock accepted")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	b := binding(root)
	b.ChainID = "other-chain"
	if _, err := Open(root, b); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale binding accepted: %v", err)
	}
}

func TestConcurrentIntentsOnlyClaimOneMutation(t *testing.T) {
	root := filepath.Join(t.TempDir(), "parallel")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	start := make(chan struct{})
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() { <-start; results <- l.RecordIntent("stage", contract.Receipt{Phase: contract.Stage}) }()
	}
	close(start)
	a, b := <-results, <-results
	if (a == nil) == (b == nil) {
		t.Fatalf("wanted exactly one intent winner, got %v and %v", a, b)
	}
}

func TestJournalTamperAfterOpenBlocksMutation(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tampered")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if err := os.WriteFile(filepath.Join(root, journalName), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := l.RecordIntent("stage", contract.Receipt{Phase: contract.Stage}); !errors.Is(err, ErrConflict) {
		t.Fatalf("tampered journal accepted: %v", err)
	}
	_, state, _, _ := l.Snapshot()
	if state != contract.Unknown {
		t.Fatalf("CAS conflict did not quarantine handle: %s", state)
	}
}

func TestOneShotInitAndInterruptedMutationQuarantine(t *testing.T) {
	root := filepath.Join(t.TempDir(), "run")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	if err := l.ClaimInit(); err != nil {
		t.Fatal(err)
	}
	if err := l.ClaimInit(); !errors.Is(err, ErrConflict) {
		t.Fatalf("second init claim accepted: %v", err)
	}
	intent := contract.Receipt{Phase: contract.Run, Operation: "init", State: contract.Running}
	if err := l.RecordIntent("init", intent); err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	l, err = Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	_, state, _, receipts := l.Snapshot()
	if state != contract.Unknown || len(receipts) != 2 || receipts[0].State != contract.Running || receipts[1].State != contract.Unknown {
		t.Fatalf("pending mutation not quarantined: %s %+v", state, receipts)
	}
	if err := l.RecordIntent("retry", intent); !errors.Is(err, ErrQuarantined) {
		t.Fatalf("quarantined run mutated: %v", err)
	}
	if err := l.Reconcile(contract.Receipt{Phase: contract.Verify, Reason: "read-only inspection"}); err != nil {
		t.Fatal(err)
	}
	_, state, _, _ = l.Snapshot()
	if state != contract.Unknown {
		t.Fatalf("reconciliation cleared quarantine: %s", state)
	}
}

func TestCrashAfterInitClaimIsUnknown(t *testing.T) {
	root := filepath.Join(t.TempDir(), "claimed-run")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	if err := l.ClaimInit(); err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	l, err = Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	_, state, _, receipts := l.Snapshot()
	if state != contract.Unknown || len(receipts) != 2 || receipts[0].State != contract.Running || receipts[1].State != contract.Unknown {
		t.Fatalf("claim crash was not quarantined: %s %+v", state, receipts)
	}
}

func TestResultRenameFailureReopensUnknownWithoutInitReplay(t *testing.T) {
	root := filepath.Join(t.TempDir(), "rename-failure")
	ops := &faultOps{}
	l, err := openWithOps(root, binding(root), ops)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	adapter := mutationFunc(func(_ context.Context, b contract.RunBinding, op string) (contract.Receipt, error) {
		calls++
		ops.failRename = true
		d, _ := contract.Digest(b)
		return contract.Receipt{SchemaVersion: contract.Version, RunID: b.RunID, BindingDigest: d, Phase: contract.Stage, Operation: op, State: contract.Succeeded}, nil
	})
	if _, err := l.Execute(context.Background(), "init", contract.Receipt{Phase: contract.Stage}, adapter); err == nil {
		t.Fatal("injected result rename failure hidden")
	}
	if calls != 1 {
		t.Fatalf("adapter calls=%d", calls)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	ops.failRename = false
	l, err = Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	_, state, _, receipts := l.Snapshot()
	if state != contract.Unknown || len(receipts) != 2 || receipts[1].State != contract.Unknown {
		t.Fatalf("rename failure not quarantined on reopen: %s %+v", state, receipts)
	}
	if err := l.RecordIntent("init", contract.Receipt{Phase: contract.Stage}); !errors.Is(err, ErrQuarantined) {
		t.Fatalf("init replay accepted: %v", err)
	}
}

func TestFailedAndBlockedResultsAreTerminal(t *testing.T) {
	for _, state := range []contract.State{contract.Failed, contract.Blocked} {
		t.Run(string(state), func(t *testing.T) {
			root := filepath.Join(t.TempDir(), string(state))
			l, err := Open(root, binding(root))
			if err != nil {
				t.Fatal(err)
			}
			defer l.Close()
			if err := l.RecordIntent("stage", contract.Receipt{Phase: contract.Stage}); err != nil {
				t.Fatal(err)
			}
			if err := l.RecordResult(contract.Receipt{Phase: contract.Stage, State: state}); err != nil {
				t.Fatal(err)
			}
			_, got, _, _ := l.Snapshot()
			if got != state {
				t.Fatalf("terminal state=%s want %s", got, state)
			}
			if err := l.RecordIntent("run", contract.Receipt{Phase: contract.Run}); !errors.Is(err, ErrConflict) {
				t.Fatalf("mutation after %s accepted: %v", state, err)
			}
			if err := l.Finalize(contract.Receipt{Phase: contract.Report}); !errors.Is(err, ErrConflict) {
				t.Fatalf("finalize after %s accepted: %v", state, err)
			}
		})
	}
}

func TestMultiPhaseRunCanClaimInitAndReopenFinalized(t *testing.T) {
	root := filepath.Join(t.TempDir(), "phases")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range []struct {
		op    string
		phase contract.Phase
	}{{"capture", contract.Capture}, {"init", contract.Stage}, {"run", contract.Run}, {"verify", contract.Verify}} {
		if err := l.RecordIntent(step.op, contract.Receipt{Phase: step.phase}); err != nil {
			t.Fatalf("intent %s: %v", step.op, err)
		}
		if err := l.RecordResult(contract.Receipt{Phase: step.phase, State: contract.Succeeded}); err != nil {
			t.Fatalf("result %s: %v", step.op, err)
		}
	}
	if err := l.Finalize(contract.Receipt{Phase: contract.Report}); err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	l, err = Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	_, state, _, receipts := l.Snapshot()
	if state != contract.Succeeded || len(receipts) != 9 {
		t.Fatalf("multi-phase history changed on reopen: %s entries=%d", state, len(receipts))
	}
}

func TestIntentResultAndAdapterBoundary(t *testing.T) {
	root := filepath.Join(t.TempDir(), "run")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if err := l.ClaimInit(); err != nil {
		t.Fatal(err)
	}
	if err := l.RecordIntent("init", contract.Receipt{Phase: contract.Stage}); err != nil {
		t.Fatal(err)
	}
	if err := l.RecordResult(contract.Receipt{Phase: contract.Stage, State: contract.Succeeded}); err != nil {
		t.Fatal(err)
	}
	_, state, _, receipts := l.Snapshot()
	if state != contract.Running || len(receipts) != 2 || receipts[0].State != contract.Running || receipts[1].State != contract.Succeeded {
		t.Fatalf("result not durable in memory: %s %+v", state, receipts)
	}
	if err := l.Finalize(contract.Receipt{Phase: contract.Report}); err != nil {
		t.Fatal(err)
	}
	_, state, _, _ = l.Snapshot()
	if state != contract.Succeeded {
		t.Fatalf("run did not finalize: %s", state)
	}
}

func TestResultOperationMustMatchIntent(t *testing.T) {
	root := filepath.Join(t.TempDir(), "mismatch")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if err := l.RecordIntent("stage", contract.Receipt{Phase: contract.Stage}); err != nil {
		t.Fatal(err)
	}
	if err := l.RecordResult(contract.Receipt{Phase: contract.Stage, Operation: "run", State: contract.Succeeded}); !errors.Is(err, ErrConflict) {
		t.Fatalf("mismatched result accepted: %v", err)
	}
	if err := l.RecordResult(contract.Receipt{Phase: contract.Stage, Operation: "stage", State: contract.Succeeded}); err != nil {
		t.Fatal(err)
	}
}

func TestCloseWaitsForMutationAdapter(t *testing.T) {
	root := filepath.Join(t.TempDir(), "inflight")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	executeDone := make(chan error, 1)
	go func() {
		_, err := l.Execute(context.Background(), "init", contract.Receipt{Phase: contract.Stage}, blockingMutation{started, release})
		executeDone <- err
	}()
	<-started
	closeDone := make(chan error, 1)
	go func() { closeDone <- l.Close() }()
	select {
	case err := <-closeDone:
		t.Fatalf("Close returned during adapter call: %v", err)
	default:
	}
	close(release)
	if err := <-executeDone; err != nil {
		t.Fatal(err)
	}
	if err := <-closeDone; err != nil {
		t.Fatal(err)
	}
}

func TestCleanupRequiresSuccessAndConfirmedOwnership(t *testing.T) {
	root := filepath.Join(t.TempDir(), "run")
	l, err := Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	denied := &cleanupMock{validateErr: errors.New("foreign resource")}
	if _, err := l.Cleanup(context.Background(), denied); !errors.Is(err, ErrConflict) {
		t.Fatalf("cleanup before success accepted: %v", err)
	}
	if denied.validated || denied.cleaned {
		t.Fatal("cleanup adapter reached before successful terminal state")
	}
	if err := l.ClaimInit(); err != nil {
		t.Fatal(err)
	}
	if err := l.RecordIntent("init", contract.Receipt{Phase: contract.Stage}); err != nil {
		t.Fatal(err)
	}
	if err := l.RecordResult(contract.Receipt{Phase: contract.Stage, State: contract.Succeeded}); err != nil {
		t.Fatal(err)
	}
	if err := l.Finalize(contract.Receipt{Phase: contract.Report}); err != nil {
		t.Fatal(err)
	}
	if _, err := l.Cleanup(context.Background(), denied); err == nil || !denied.validated || denied.cleaned {
		t.Fatal("ownership refusal did not stop cleanup")
	}
	allowed := &cleanupMock{}
	if _, err := l.Cleanup(context.Background(), allowed); err != nil {
		t.Fatal(err)
	}
	if !allowed.validated || !allowed.cleaned || allowed.binding.RunID != "run-1" {
		t.Fatal("cleanup did not receive bound run identity")
	}
	if _, err := l.Cleanup(context.Background(), allowed); !errors.Is(err, ErrConflict) {
		t.Fatalf("repeated cleanup accepted: %v", err)
	}
}

func TestPathEscapeAndSymlinkRefusal(t *testing.T) {
	parent := t.TempDir()
	outside := t.TempDir()
	link := filepath.Join(parent, "link")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	root := filepath.Join(link, "run")
	if _, err := Open(root, binding(root)); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("symlink path accepted: %v", err)
	}
	b := binding(filepath.Join(parent, "valid"))
	b.Paths = map[string]string{"escape": filepath.Join(parent, "..", "outside")}
	if _, err := Open(b.Workspace, b); err == nil {
		t.Fatal("bound path escape accepted")
	}
}

func TestJournalSymlinkAndHardlinkRefusal(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink"} {
		t.Run(kind, func(t *testing.T) {
			parent := t.TempDir()
			root := filepath.Join(parent, "run")
			if err := os.Mkdir(root, 0o700); err != nil {
				t.Fatal(err)
			}
			outside := filepath.Join(parent, "outside")
			if err := os.WriteFile(outside, []byte("foreign"), 0o600); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(root, journalName)
			if kind == "symlink" {
				if err := os.Symlink(outside, target); err != nil {
					t.Skipf("symlink unavailable: %v", err)
				}
			} else {
				if err := os.Link(outside, target); err != nil {
					t.Skipf("hardlink unavailable: %v", err)
				}
			}
			if _, err := Open(root, binding(root)); !errors.Is(err, ErrUnsafePath) {
				t.Fatalf("%s journal accepted: %v", kind, err)
			}
		})
	}
}

func TestJournalReplacementAfterOpenFailsClosed(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink"} {
		t.Run(kind, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "run")
			l, err := Open(root, binding(root))
			if err != nil {
				t.Fatal(err)
			}
			defer l.Close()
			outside := filepath.Join(t.TempDir(), "outside")
			want := []byte("outside stays intact")
			if err := os.WriteFile(outside, want, 0o600); err != nil {
				t.Fatal(err)
			}
			journal := filepath.Join(root, journalName)
			if err := os.Remove(journal); err != nil {
				t.Fatal(err)
			}
			if kind == "symlink" {
				err = os.Symlink(outside, journal)
			} else {
				err = os.Link(outside, journal)
			}
			if err != nil {
				t.Skipf("%s unavailable: %v", kind, err)
			}
			if err := l.RecordIntent("stage", contract.Receipt{Phase: contract.Stage}); err == nil {
				t.Fatal("replacement journal accepted")
			}
			got, err := os.ReadFile(outside)
			if err != nil || string(got) != string(want) {
				t.Fatalf("outside target changed: %q %v", got, err)
			}
		})
	}
}

func TestOpenAndSnapshotCopyMutableBindingAndReceipts(t *testing.T) {
	root := filepath.Join(t.TempDir(), "copies")
	b := binding(root)
	l, err := Open(root, b)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	b.InputDigests["export"] = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	if err := l.RecordIntent("stage", contract.Receipt{Phase: contract.Stage}); err != nil {
		t.Fatal(err)
	}
	digest := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	r := contract.Receipt{Phase: contract.Stage, State: contract.Succeeded, EvidenceDigests: map[string]string{"evidence": digest}}
	if err := l.RecordResult(r); err != nil {
		t.Fatal(err)
	}
	r.EvidenceDigests["evidence"] = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	snap, _, _, receipts := l.Snapshot()
	snap.InputDigests["export"] = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
	if receipts[1].EvidenceDigests["evidence"] != digest {
		t.Fatal("receipt map alias escaped lifecycle")
	}
	got, _, _, _ := l.Snapshot()
	if got.InputDigests["export"] != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatal("binding map alias escaped lifecycle")
	}
}

func TestENOSPCLeavesPreMutationState(t *testing.T) {
	root := filepath.Join(t.TempDir(), "run")
	ops := &faultOps{}
	l, err := openWithOps(root, binding(root), ops)
	if err != nil {
		t.Fatal(err)
	}
	ops.fail = true
	if err := l.ClaimInit(); err == nil {
		t.Fatal("simulated ENOSPC was hidden")
	}
	if l.doc.InitClaimed {
		t.Fatal("failed journal write changed in-memory init state")
	}
	ops.fail = false
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	l, err = Open(root, binding(root))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if err := l.ClaimInit(); err != nil {
		t.Fatalf("init retry after pre-intent ENOSPC refused: %v", err)
	}
}
