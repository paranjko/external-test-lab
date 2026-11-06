package orchestration

import (
	"context"
	"errors"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/driver"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

func TestAdapterSplitsControlFromRecoveryAndClosesEveryCoordinator(t *testing.T) {
	binding := orchestrationBinding()
	var runtimes []*fixtureRuntime
	adapter := &Adapter{
		Build: func(got contract.RunBinding) (Runtime, error) {
			if got.RunID != binding.RunID {
				t.Fatal("binding was not passed to coordinator builder")
			}
			runtime := &fixtureRuntime{}
			runtimes = append(runtimes, runtime)
			return runtime, nil
		},
		Snapshots: fixtureSnapshots{},
	}
	if err := adapter.Preflight(context.Background(), binding); err != nil {
		t.Fatal(err)
	}
	if _, err := adapter.ExecuteStage(context.Background(), binding); err != nil {
		t.Fatal(err)
	}
	if _, err := adapter.ExecuteRun(context.Background(), binding); err != nil {
		t.Fatal(err)
	}
	if len(runtimes) != 3 || !runtimes[0].closed || !runtimes[1].closed || !runtimes[2].closed {
		t.Fatalf("each phase must close its private coordinator: %#v", runtimes)
	}
	if got := runtimes[1].through; got != driver.ControlStop {
		t.Fatalf("stage executed %q, want control prefix", got)
	}
	if !runtimes[2].ran || runtimes[2].through != "" {
		t.Fatalf("run must resume full coordinator, got %#v", runtimes[2])
	}
}

func TestAdapterRefusesMissingCompositionBeforeRuntime(t *testing.T) {
	binding := orchestrationBinding()
	if err := (&Adapter{}).Preflight(context.Background(), binding); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("missing composition error = %v", err)
	}
}

func TestAdapterDoesNotReadSnapshotsWhenRuntimeFails(t *testing.T) {
	binding := orchestrationBinding()
	snapshots := &countingSnapshots{}
	adapter := &Adapter{Build: func(contract.RunBinding) (Runtime, error) {
		return &fixtureRuntime{throughErr: errors.New("control failed")}, nil
	}, Snapshots: snapshots}
	if _, err := adapter.ExecuteStage(context.Background(), binding); err == nil {
		t.Fatal("failed control prefix accepted")
	}
	if snapshots.topologyCalls != 0 || snapshots.runCalls != 0 {
		t.Fatalf("snapshots read after failed runtime: %#v", snapshots)
	}
}

type fixtureRuntime struct {
	through    driver.Step
	throughErr error
	ran        bool
	closed     bool
}

func (r *fixtureRuntime) RunThrough(_ context.Context, step driver.Step) error {
	r.through = step
	return r.throughErr
}
func (r *fixtureRuntime) Run(context.Context) (driver.Result, error) {
	r.ran = true
	return driver.Result{}, nil
}
func (r *fixtureRuntime) Close() error { r.closed = true; return nil }

type fixtureSnapshots struct{}

func (fixtureSnapshots) TopologyAfter(context.Context, contract.RunBinding) (contract.Snapshot, error) {
	return fixtureSnapshot("control"), nil
}
func (fixtureSnapshots) RunSnapshots(context.Context, contract.RunBinding) (session.RunSnapshots, error) {
	snapshot := fixtureSnapshot("recovery")
	return session.RunSnapshots{MigrationBefore: snapshot, MigrationAfter: snapshot, BlockBefore: snapshot, BlockAfter: snapshot}, nil
}

type countingSnapshots struct{ topologyCalls, runCalls int }

func (s *countingSnapshots) TopologyAfter(context.Context, contract.RunBinding) (contract.Snapshot, error) {
	s.topologyCalls++
	return contract.Snapshot{}, nil
}
func (s *countingSnapshots) RunSnapshots(context.Context, contract.RunBinding) (session.RunSnapshots, error) {
	s.runCalls++
	return session.RunSnapshots{}, nil
}

func fixtureSnapshot(value string) contract.Snapshot {
	return contract.Snapshot{Stores: []contract.LogicalStore{{Name: "application", Entries: []contract.Entry{{Key: []byte("k"), Value: []byte(value)}}}}}
}

func orchestrationBinding() contract.RunBinding {
	return contract.RunBinding{RunID: "run-001", Workspace: "/tmp/gnklab-run", Scenario: contract.Scenario}
}
