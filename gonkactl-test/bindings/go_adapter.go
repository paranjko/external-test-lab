// Package bindings adapts executable test events without manufacturing Gherkin
// step evidence where an upstream runner did not emit it.
package bindings

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

type GoTestSelector struct {
	SourceRevision string `json:"source_revision"`
	Module         string `json:"module"`
	ModuleVersion  string `json:"module_version"`
	ModuleSum      string `json:"module_sum"`
	Package        string `json:"package"`
	Test           string `json:"test"`
}

func (s GoTestSelector) Validate() error {
	if s.SourceRevision == "" || s.Module == "" || s.ModuleVersion == "" || s.ModuleSum == "" || s.Package == "" || s.Test == "" {
		return fmt.Errorf("source revision, module version/checksum, package, and test selector are required")
	}
	return nil
}

type GoTestEvent struct {
	Action  string  `json:"Action"`
	Package string  `json:"Package"`
	Test    string  `json:"Test"`
	Elapsed float64 `json:"Elapsed"`
	Output  string  `json:"Output"`
}

type ExecutionEvent struct {
	Kind         string
	Test         string
	Outcome      string
	ElapsedMS    int64
	StepEvidence string
}

type GoTestReceipt struct {
	Selector    GoTestSelector   `json:"selector"`
	Command     []string         `json:"command"`
	StartedAt   string           `json:"started_at"`
	FinishedAt  string           `json:"finished_at"`
	Events      []ExecutionEvent `json:"events"`
	ExitCode    int              `json:"exit_code"`
	Signal      string           `json:"signal,omitempty"`
	Interrupted bool             `json:"interrupted"`
	ReceiptPath string           `json:"-"`
}

// RunGoTest executes the authentic upstream command with a pinned selector.
// It owns all child temporary/cache paths and retains the process exit receipt.
func RunGoTest(ctx context.Context, directory, dataRoot string, selector GoTestSelector, extraArgs ...string) (GoTestReceipt, error) {
	if err := selector.Validate(); err != nil {
		return GoTestReceipt{}, err
	}
	if err := ValidatePersistentPath(filepath.Join(dataRoot, "probe")); err != nil {
		return GoTestReceipt{}, err
	}
	env, err := PersistentEnvironment(dataRoot)
	if err != nil {
		return GoTestReceipt{}, err
	}
	if err := verifyModule(ctx, directory, env, selector); err != nil {
		return GoTestReceipt{}, err
	}
	pattern := "^" + regexp.QuoteMeta(selector.Test) + "$"
	args := []string{"test", "-json", "-count=1", "-run", pattern}
	args = append(args, extraArgs...)
	args = append(args, selector.Package)
	cmd := exec.CommandContext(ctx, "go", args...)
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), env...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return GoTestReceipt{}, err
	}
	cmd.Stderr = cmd.Stdout
	started := time.Now()
	if err := cmd.Start(); err != nil {
		return GoTestReceipt{}, err
	}
	events, parseErr := AdaptGoTestJSON(stdout, selector)
	waitErr := cmd.Wait()
	receipt := GoTestReceipt{Selector: selector, Command: append([]string{"go"}, args...), StartedAt: started.UTC().Format(time.RFC3339Nano), Events: events}
	if cmd.ProcessState != nil {
		receipt.ExitCode = cmd.ProcessState.ExitCode()
		if status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			receipt.Signal = status.Signal().String()
		}
	}
	if ctx.Err() != nil {
		receipt.Interrupted = true
		if receipt.Signal == "" {
			receipt.Signal = "context-canceled"
		}
		if len(receipt.Events) == 0 {
			receipt.Events = []ExecutionEvent{{Kind: "test_started", Test: selector.Test, StepEvidence: "unavailable"}, {Kind: "test_finished", Test: selector.Test, Outcome: "interrupted", StepEvidence: "unavailable"}}
		}
	}
	if len(receipt.Events) == 0 && receipt.ExitCode != 0 && !receipt.Interrupted {
		receipt.Events = []ExecutionEvent{{Kind: "test_started", Test: selector.Test, StepEvidence: "unavailable"}, {Kind: "test_finished", Test: selector.Test, Outcome: "fail", StepEvidence: "unavailable"}}
	}
	if parseErr != nil {
		return receipt, parseErr
	}
	if len(receipt.Events) == 0 {
		return receipt, fmt.Errorf("selected upstream test emitted no events")
	}
	if waitErr != nil && receipt.ExitCode == 0 && !receipt.Interrupted {
		return receipt, waitErr
	}
	receipt.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	path, err := writeGoReceipt(dataRoot, receipt)
	if err != nil {
		return receipt, err
	}
	receipt.ReceiptPath = path
	return receipt, nil
}

func verifyModule(ctx context.Context, directory string, env []string, s GoTestSelector) error {
	cmd := exec.CommandContext(ctx, "go", "mod", "download", "-json", s.Module+"@"+s.ModuleVersion)
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("verify pinned module: %w", err)
	}
	var got struct {
		Path, Version, Sum string
		Origin             struct{ Hash string }
	}
	if err := json.Unmarshal(out, &got); err != nil {
		return err
	}
	if got.Path != s.Module || got.Version != s.ModuleVersion || got.Sum != s.ModuleSum || !strings.EqualFold(got.Origin.Hash, s.SourceRevision) {
		return fmt.Errorf("pinned source mismatch: path=%s version=%s sum=%s revision=%s", got.Path, got.Version, got.Sum, got.Origin.Hash)
	}
	return nil
}
func writeGoReceipt(root string, r GoTestReceipt) (string, error) {
	encoded, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, "process-receipts")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, fmt.Sprintf("%d-%d.json", os.Getpid(), time.Now().UnixNano()))
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	if _, err = f.Write(append(encoded, '\n')); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return "", err
	}
	return path, closeErr
}

// AdaptGoTestJSON maps only actual go test -json lifecycle events. It returns
// test-level evidence with step_evidence=unavailable; callers must not invent
// passed Given/When/Then steps from a package PASS.
func AdaptGoTestJSON(r io.Reader, selector GoTestSelector) ([]ExecutionEvent, error) {
	if err := selector.Validate(); err != nil {
		return nil, err
	}
	var events []ExecutionEvent
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		var raw GoTestEvent
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			return nil, fmt.Errorf("decode go test event: %w", err)
		}
		if raw.Package != selector.Package || raw.Test != selector.Test {
			continue
		}
		switch raw.Action {
		case "run":
			events = append(events, ExecutionEvent{Kind: "test_started", Test: raw.Test, StepEvidence: "unavailable"})
		case "pass", "fail", "skip":
			events = append(events, ExecutionEvent{Kind: "test_finished", Test: raw.Test, Outcome: raw.Action, ElapsedMS: int64(raw.Elapsed * 1000), StepEvidence: "unavailable"})
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return events, nil
}
