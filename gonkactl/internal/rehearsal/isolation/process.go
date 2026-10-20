package isolation

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type Operation string

const (
	OperationCreateContainer  Operation = "create-container"
	OperationInspectImage     Operation = "inspect-image"
	OperationInspectResources Operation = "inspect-resources"
	OperationStartContainer   Operation = "start-container"
	OperationStopContainer    Operation = "stop-container"
	OperationKillContainer    Operation = "kill-container"
	OperationRemoveContainer  Operation = "remove-container"
	OperationCreateNetwork    Operation = "create-network"
	OperationInspectNetwork   Operation = "inspect-network"
	OperationRemoveNetwork    Operation = "remove-network"
	operationTestHelper       Operation = "test-helper"
)

var (
	ErrCommandPolicy  = errors.New("runtime command violates process policy")
	ErrOutputLimit    = errors.New("runtime command exceeded output limit")
	ErrProcessExit    = errors.New("runtime command exited unsuccessfully")
	ErrProcessTimeout = errors.New("runtime command timed out")
)

// ImageInspectCommand and ResourcesInspectCommand are the only inspection
// builders. They accept typed image references and exact resource IDs.
func ImageInspectCommand(executable, image string) (Command, error) {
	if !validImageDigest(image) {
		return Command{}, ErrUnsafeSpec
	}
	return newCommand(OperationInspectImage, executable, []string{"image", "inspect", image}), nil
}
func ResourcesInspectCommand(executable string, ids []string) (Command, error) {
	if len(ids) == 0 {
		return Command{}, ErrUnsafeSpec
	}
	args := []string{"inspect", "--type", "container"}
	seen := map[string]bool{}
	for _, id := range ids {
		if !safeResourceID(id) || seen[id] {
			return Command{}, ErrUnsafeSpec
		}
		seen[id] = true
		args = append(args, id)
	}
	return newCommand(OperationInspectResources, executable, args), nil
}

func networkCreateCommand(executable, name string, b contract.RunBinding, digest string) (Command, error) {
	if !safeName.MatchString(name) || name != "gnk-"+b.RunID {
		return Command{}, ErrUnsafeSpec
	}
	labels := map[string]string{"gonka.rehearsal.run": b.RunID, "gonka.rehearsal.owner": b.OwnershipMarker, "gonka.rehearsal.binding": digest}
	args := []string{"network", "create", "--driver", "bridge", "--internal"}
	for _, k := range sortedKeys(labels) {
		args = append(args, "--label", k+"="+labels[k])
	}
	args = append(args, name)
	return newCommand(OperationCreateNetwork, executable, args), nil
}
func NetworkInspectCommand(executable, id string) (Command, error) {
	if !safeRuntimeID(id) {
		return Command{}, ErrUnsafeSpec
	}
	return newCommand(OperationInspectNetwork, executable, []string{"network", "inspect", id}), nil
}
func networkActionCommand(executable string, op Operation, id string) (Command, error) {
	if !safeRuntimeID(id) || op != OperationRemoveNetwork {
		return Command{}, ErrUnsafeSpec
	}
	return newCommand(op, executable, []string{"network", "rm", id}), nil
}

func containerActionCommand(executable string, operation Operation, id string) (Command, error) {
	if !safeRuntimeID(id) {
		return Command{}, ErrUnsafeSpec
	}
	var args []string
	switch operation {
	case OperationStartContainer:
		args = []string{"start", id}
	case OperationStopContainer:
		args = []string{"stop", id}
	case OperationKillContainer:
		args = []string{"kill", "--signal", "KILL", id}
	case OperationRemoveContainer:
		args = []string{"rm", id}
	default:
		return Command{}, ErrUnsafeSpec
	}
	return newCommand(operation, executable, args), nil
}

func safeResourceID(id string) bool {
	if safeName.MatchString(id) {
		return true
	}
	if len(id) < 12 || len(id) > 64 {
		return false
	}
	for _, r := range id {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

func newCommand(op Operation, executable string, args []string) Command {
	c := Command{operation: op, executable: executable, args: append([]string(nil), args...)}
	c.seal = commandSeal(c)
	return c
}
func commandSeal(c Command) string {
	var b strings.Builder
	b.WriteString(string(c.operation))
	b.WriteByte(0)
	b.WriteString(c.executable)
	b.WriteByte(0)
	for _, arg := range c.args {
		b.WriteString(arg)
		b.WriteByte(0)
	}
	h := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(h[:])
}

type ProcessPolicy struct {
	Executables    []string
	Operations     []Operation
	Timeout        time.Duration
	MaxOutputBytes int
}
type NativeRunner struct {
	executables map[string]bool
	operations  map[Operation]bool
	timeout     time.Duration
	outputLimit int
}

func NewNativeRunner(policy ProcessPolicy) (*NativeRunner, error) {
	if policy.Timeout <= 0 || policy.Timeout > 10*time.Minute || policy.MaxOutputBytes <= 0 || policy.MaxOutputBytes > 16*1024*1024 || len(policy.Executables) == 0 || len(policy.Operations) == 0 {
		return nil, ErrCommandPolicy
	}
	r := &NativeRunner{executables: map[string]bool{}, operations: map[Operation]bool{}, timeout: policy.Timeout, outputLimit: policy.MaxOutputBytes}
	for _, executable := range policy.Executables {
		if !filepath.IsAbs(executable) || filepath.Clean(executable) != executable {
			return nil, ErrCommandPolicy
		}
		r.executables[executable] = true
	}
	for _, op := range policy.Operations {
		if op != OperationCreateContainer && op != OperationInspectImage && op != OperationInspectResources && op != OperationStartContainer && op != OperationStopContainer && op != OperationKillContainer && op != OperationRemoveContainer && op != OperationCreateNetwork && op != OperationInspectNetwork && op != OperationRemoveNetwork && op != operationTestHelper {
			return nil, ErrCommandPolicy
		}
		r.operations[op] = true
	}
	return r, nil
}

type ProcessFailure struct {
	Operation     Operation
	CommandDigest string
	ExitCode      int
	Cause         error
}

func (e *ProcessFailure) Error() string {
	return fmt.Sprintf("%s: operation %s exit code %d", e.Cause, e.Operation, e.ExitCode)
}
func (e *ProcessFailure) Unwrap() error { return e.Cause }

func (r *NativeRunner) Run(parent context.Context, c Command) ([]byte, []byte, int, error) {
	if parent == nil || r == nil || !r.executables[c.executable] || !r.operations[c.operation] || c.seal == "" || c.seal != commandSeal(c) || !validOperationArgs(c) {
		return nil, nil, -1, ErrCommandPolicy
	}
	ctx, cancel := context.WithTimeout(parent, r.timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.executable, c.args...)
	cmd.Env = cleanEnvironment()
	cmd.Dir = string(filepath.Separator)
	out := &boundedOutput{limit: r.outputLimit}
	stderr := &boundedOutput{limit: r.outputLimit}
	kill := func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	out.onOverflow = kill
	stderr.onOverflow = kill
	cmd.Stdout = out
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return nil, nil, -1, &ProcessFailure{Operation: c.operation, CommandDigest: c.seal, ExitCode: -1, Cause: err}
	}
	err := cmd.Wait()
	exit := 0
	if cmd.ProcessState != nil {
		exit = cmd.ProcessState.ExitCode()
	} else if err != nil {
		exit = -1
	}
	if out.overflow.Load() || stderr.overflow.Load() {
		return out.Bytes(), stderr.Bytes(), exit, &ProcessFailure{Operation: c.operation, CommandDigest: c.seal, ExitCode: exit, Cause: ErrOutputLimit}
	}
	if ctx.Err() != nil {
		cause := ErrProcessTimeout
		if errors.Is(ctx.Err(), context.Canceled) {
			cause = context.Canceled
		}
		return out.Bytes(), stderr.Bytes(), exit, &ProcessFailure{Operation: c.operation, CommandDigest: c.seal, ExitCode: exit, Cause: cause}
	}
	if err != nil {
		return out.Bytes(), stderr.Bytes(), exit, &ProcessFailure{Operation: c.operation, CommandDigest: c.seal, ExitCode: exit, Cause: fmt.Errorf("%w: %v", ErrProcessExit, err)}
	}
	return out.Bytes(), stderr.Bytes(), exit, nil
}

func validOperationArgs(c Command) bool {
	switch c.operation {
	case OperationCreateContainer:
		return validCreateArgs(c.args)
	case OperationCreateNetwork:
		return validNetworkCreateArgs(c.args)
	case OperationInspectNetwork:
		return len(c.args) == 3 && c.args[0] == "network" && c.args[1] == "inspect" && safeRuntimeID(c.args[2])
	case OperationRemoveNetwork:
		return len(c.args) == 3 && c.args[0] == "network" && c.args[1] == "rm" && safeRuntimeID(c.args[2])
	case OperationInspectImage:
		return len(c.args) == 3 && c.args[0] == "image" && c.args[1] == "inspect" && validImageDigest(c.args[2])
	case OperationInspectResources:
		if len(c.args) < 4 || c.args[0] != "inspect" || c.args[1] != "--type" || c.args[2] != "container" {
			return false
		}
		seen := map[string]bool{}
		for _, id := range c.args[3:] {
			if !safeResourceID(id) || seen[id] {
				return false
			}
			seen[id] = true
		}
		return true
	case OperationStartContainer:
		return len(c.args) == 2 && c.args[0] == "start" && safeRuntimeID(c.args[1])
	case OperationStopContainer:
		return len(c.args) == 2 && c.args[0] == "stop" && safeRuntimeID(c.args[1])
	case OperationKillContainer:
		return len(c.args) == 4 && c.args[0] == "kill" && c.args[1] == "--signal" && c.args[2] == "KILL" && safeRuntimeID(c.args[3])
	case OperationRemoveContainer:
		return len(c.args) == 2 && c.args[0] == "rm" && safeRuntimeID(c.args[1])
	case operationTestHelper:
		return len(c.args) > 0
	default:
		return false
	}
}

func validCreateArgs(args []string) bool {
	if len(args) < 5 || args[0] != "create" || args[1] != "--name" || !safeName.MatchString(args[2]) || args[3] != "--network" {
		return false
	}
	network := args[4]
	if network != "none" && !safeName.MatchString(network) {
		return false
	}
	if network != "none" {
		for _, arg := range args {
			if arg == "--publish" {
				return false
			}
		}
	}
	return true
}
func validNetworkCreateArgs(a []string) bool {
	if len(a) != 12 || a[0] != "network" || a[1] != "create" || a[2] != "--driver" || a[3] != "bridge" || a[4] != "--internal" {
		return false
	}
	labels := map[string]string{}
	for i := 5; i < len(a)-1; i += 2 {
		if a[i] != "--label" {
			return false
		}
		kv := strings.SplitN(a[i+1], "=", 2)
		if len(kv) != 2 {
			return false
		}
		if _, exists := labels[kv[0]]; exists {
			return false
		}
		labels[kv[0]] = kv[1]
	}
	name := a[len(a)-1]
	if !safeName.MatchString(name) || !strings.HasPrefix(name, "gnk-") || len(labels) != 3 {
		return false
	}
	return labels["gonka.rehearsal.run"] == strings.TrimPrefix(name, "gnk-") && labels["gonka.rehearsal.owner"] != "" && validDigestHex(labels["gonka.rehearsal.binding"])
}
func validDigestHex(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func safeRuntimeID(id string) bool { return len(id) == 64 && safeResourceID(id) }

type boundedOutput struct {
	mu         sync.Mutex
	buffer     bytes.Buffer
	limit      int
	overflow   atomic.Bool
	onOverflow func()
}

func (b *boundedOutput) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	remaining := b.limit - b.buffer.Len()
	if remaining <= 0 {
		if len(p) > 0 {
			b.overflow.Store(true)
			if b.onOverflow != nil {
				b.onOverflow()
			}
		}
		return len(p), nil
	}
	if len(p) > remaining {
		_, _ = b.buffer.Write(p[:remaining])
		b.overflow.Store(true)
		if b.onOverflow != nil {
			b.onOverflow()
		}
		return len(p), nil
	}
	return b.buffer.Write(p)
}
func (b *boundedOutput) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]byte(nil), b.buffer.Bytes()...)
}

// Kept local so callers cannot expand the inherited environment accidentally.
func cleanEnvironment() []string { return []string{"PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C"} }
