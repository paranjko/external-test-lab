//go:build linux

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

// Synthetic adapters exercise CLI routing only, never qualify a runtime.
type phaseCLIAdapter struct {
	calls   int
	failure error
}

func (*phaseCLIAdapter) Preflight(context.Context, contract.RunBinding) error { return nil }
func (a *phaseCLIAdapter) ExecuteStage(context.Context, contract.RunBinding) (contract.Snapshot, error) {
	a.calls++
	return phaseCLISnapshot(), a.failure
}
func (a *phaseCLIAdapter) ExecuteRun(context.Context, contract.RunBinding) (session.RunSnapshots, error) {
	a.calls++
	s := phaseCLISnapshot()
	return session.RunSnapshots{MigrationBefore: s, MigrationAfter: s, BlockBefore: s, BlockAfter: s}, a.failure
}

type phaseCLIReader struct{}

func (phaseCLIReader) ReadSnapshot(_ context.Context, b contract.RunBinding) (contract.Snapshot, error) {
	if b.Paths["source"] == "" {
		return contract.Snapshot{}, errors.New("unbound source")
	}
	return phaseCLISnapshot(), nil
}
func phaseCLISnapshot() contract.Snapshot {
	return contract.Snapshot{Stores: []contract.LogicalStore{{Name: "inference", Entries: []contract.Entry{{Key: []byte("key"), Value: []byte("value")}}}}}
}
func executePhaseCLI(t *testing.T, deps RehearsalDependencies, args []string) (contract.Outcome, error) {
	t.Helper()
	cmd := newRehearsalCommand(deps)
	cmd.SetArgs(args)
	var out bytes.Buffer
	cmd.SetOut(&out)
	err := cmd.Execute()
	var result contract.Outcome
	if decodeErr := json.Unmarshal(out.Bytes(), &result); decodeErr != nil {
		t.Fatal(decodeErr)
	}
	return result, err
}
func TestRehearsalPhaseRoutingRequiresApplyAndNeverClaimsRuntimePass(t *testing.T) {
	f := newSignedCaptureCLI(t)
	a := &phaseCLIAdapter{}
	f.dependencies.CaptureSnapshotReader = phaseCLIReader{}
	f.dependencies.StageAdapter, f.dependencies.RunAdapter = a, a
	if _, err := executePhaseCLI(t, f.dependencies, f.args); err != nil {
		t.Fatal(err)
	}
	for _, phase := range []string{"stage", "run"} {
		args := []string{contract.Scenario, phase, "--workspace", f.binding.Workspace, "--run-id", f.binding.RunID}
		if phase == "run" {
			args = append(args, "--resume", f.binding.RunID)
		}
		beforeCalls := a.calls
		out, err := executePhaseCLI(t, f.dependencies, args)
		if err == nil || out.Code != "runtime_phase_inputs_incomplete" || a.calls != beforeCalls {
			t.Fatalf("missing apply accepted: %+v %v", out, err)
		}
		out, err = executePhaseCLI(t, f.dependencies, append(args, "--apply"))
		if err != nil || out.Code != phase+"_succeeded" || out.Verdict == contract.Pass || out.Qualification != "not_verified" || a.calls != beforeCalls+1 {
			t.Fatalf("phase result: %+v %v", out, err)
		}
		journalPath := filepath.Join(f.binding.Workspace, "lifecycle.json")
		before, err := os.ReadFile(journalPath)
		if err != nil {
			t.Fatal(err)
		}
		out, err = executePhaseCLI(t, f.dependencies, append(args, "--apply"))
		after, readErr := os.ReadFile(journalPath)
		if err == nil || readErr != nil || a.calls != beforeCalls+1 || !bytes.Equal(before, after) {
			t.Fatalf("repeat changed journal or executed: %+v %v", out, err)
		}
	}
}

func TestRehearsalUsesComposedRuntimeAdapterForBothPhases(t *testing.T) {
	f := newSignedCaptureCLI(t)
	a := &phaseCLIAdapter{}
	f.dependencies.CaptureSnapshotReader = phaseCLIReader{}
	f.dependencies.RuntimeAdapter = a
	if _, err := executePhaseCLI(t, f.dependencies, f.args); err != nil {
		t.Fatal(err)
	}
	for _, phase := range []string{"stage", "run"} {
		args := []string{contract.Scenario, phase, "--apply", "--workspace", f.binding.Workspace, "--run-id", f.binding.RunID}
		if phase == "run" {
			args = append(args, "--resume", f.binding.RunID)
		}
		out, err := executePhaseCLI(t, f.dependencies, args)
		if err != nil || out.Code != phase+"_succeeded" || out.Qualification != "not_verified" {
			t.Fatalf("composed %s route: %+v %v", phase, out, err)
		}
	}
	if a.calls != 2 {
		t.Fatalf("composed adapter calls = %d, want 2", a.calls)
	}
}

func TestRehearsalPhaseRefusesUnavailableAdapterAndMismatchedResumeWithoutWrites(t *testing.T) {
	f := newSignedCaptureCLI(t)
	f.dependencies.CaptureSnapshotReader = phaseCLIReader{}
	if _, err := executePhaseCLI(t, f.dependencies, f.args); err != nil {
		t.Fatal(err)
	}
	journalPath := filepath.Join(f.binding.Workspace, "lifecycle.json")
	before, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatal(err)
	}
	args := []string{contract.Scenario, "stage", "--apply", "--workspace", f.binding.Workspace, "--run-id", f.binding.RunID}
	out, err := executePhaseCLI(t, f.dependencies, args)
	if err == nil || out.Code != "phase_adapter_unavailable" || out.Mutation != "none" {
		t.Fatalf("missing production adapter did not fail closed: %+v %v", out, err)
	}
	args = append(args, "--resume", "different-run")
	out, err = executePhaseCLI(t, f.dependencies, args)
	if err == nil || out.Code != "resume_run_id_mismatch" || out.Mutation != "none" {
		t.Fatalf("mismatched resume accepted: %+v %v", out, err)
	}
	after, err := os.ReadFile(journalPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("refused dispatch modified journal: %v", err)
	}
}
func TestRehearsalPhaseErrorQuarantinesWithoutRepeat(t *testing.T) {
	f := newSignedCaptureCLI(t)
	a := &phaseCLIAdapter{failure: errors.New("synthetic interrupted operation")}
	f.dependencies.CaptureSnapshotReader = phaseCLIReader{}
	f.dependencies.StageAdapter = a
	if _, err := executePhaseCLI(t, f.dependencies, f.args); err != nil {
		t.Fatal(err)
	}
	args := []string{contract.Scenario, "stage", "--apply", "--workspace", f.binding.Workspace, "--run-id", f.binding.RunID}
	out, err := executePhaseCLI(t, f.dependencies, args)
	if err == nil || out.ExitCode != 3 || out.Verdict != contract.Inconclusive || out.Mutation != "owned_workspace" {
		t.Fatalf("unknown hidden: %+v %v", out, err)
	}
	out, err = executePhaseCLI(t, f.dependencies, args)
	if err == nil || a.calls != 1 || out.Code != "persisted_run_unavailable" {
		t.Fatalf("unknown retried: %+v %v", out, err)
	}
}
