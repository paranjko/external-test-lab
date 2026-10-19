// Package orchestration joins the durable runtime coordinator to the
// persisted session phases. It deliberately does not manufacture evidence:
// the caller must supply the independently-produced logical snapshots.
package orchestration

import (
	"context"
	"errors"
	"fmt"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/driver"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

var ErrUnavailable = errors.New("rehearsal runtime orchestration is unavailable")

// Runtime is the small coordinator surface needed by the two persisted
// session phases. It is intentionally narrower than driver.Coordinator so
// tests cannot accidentally treat a fabricated driver result as evidence.
type Runtime interface {
	RunThrough(context.Context, driver.Step) error
	Run(context.Context) (driver.Result, error)
	Close() error
}

// Build opens one run-owned coordinator and its durable journal. A fresh
// instance is constructed for each CLI invocation; the journal determines the
// only safe resume point and rejects pending or unknown mutations.
type Build func(contract.RunBinding) (Runtime, error)

// Snapshots obtains independently-produced, run-bound full logical snapshots.
// It must not be implemented by an assertion-only test double in production.
// Session validates completeness and persists the resulting digest itself.
type Snapshots interface {
	TopologyAfter(context.Context, contract.RunBinding) (contract.Snapshot, error)
	RunSnapshots(context.Context, contract.RunBinding) (session.RunSnapshots, error)
}

// Adapter implements both session phase adapters. Stage drives only the
// signerless control prefix. Run resumes the same driver journal at recovery
// creation and owns the repair, stopped-store, standard handoff and H+1
// sequence. Therefore a retry never repeats repair after a durable prefix.
type Adapter struct {
	Build     Build
	Snapshots Snapshots
}

var _ session.StageAdapter = (*Adapter)(nil)
var _ session.RunAdapter = (*Adapter)(nil)

func (a *Adapter) Preflight(_ context.Context, binding contract.RunBinding) error {
	if a == nil || a.Build == nil || a.Snapshots == nil {
		return ErrUnavailable
	}
	runtime, err := a.Build(binding)
	if err != nil {
		return fmt.Errorf("open run-owned runtime coordinator: %w", err)
	}
	if runtime == nil {
		return ErrUnavailable
	}
	if err := runtime.Close(); err != nil {
		return fmt.Errorf("close preflight runtime coordinator: %w", err)
	}
	return nil
}

func (a *Adapter) ExecuteStage(ctx context.Context, binding contract.RunBinding) (contract.Snapshot, error) {
	if err := a.require(); err != nil {
		return contract.Snapshot{}, err
	}
	runtime, err := a.Build(binding)
	if err != nil {
		return contract.Snapshot{}, fmt.Errorf("open stage runtime coordinator: %w", err)
	}
	if runtime == nil {
		return contract.Snapshot{}, ErrUnavailable
	}
	if err := runtime.RunThrough(ctx, driver.ControlStop); err != nil {
		_ = runtime.Close()
		return contract.Snapshot{}, fmt.Errorf("execute signerless control prefix: %w", err)
	}
	snapshot, err := a.Snapshots.TopologyAfter(ctx, binding)
	if err != nil {
		_ = runtime.Close()
		return contract.Snapshot{}, fmt.Errorf("read independently-produced staged topology: %w", err)
	}
	if err := runtime.Close(); err != nil {
		return contract.Snapshot{}, fmt.Errorf("close stage runtime coordinator: %w", err)
	}
	return snapshot, nil
}

func (a *Adapter) ExecuteRun(ctx context.Context, binding contract.RunBinding) (session.RunSnapshots, error) {
	if err := a.require(); err != nil {
		return session.RunSnapshots{}, err
	}
	runtime, err := a.Build(binding)
	if err != nil {
		return session.RunSnapshots{}, fmt.Errorf("open run runtime coordinator: %w", err)
	}
	if runtime == nil {
		return session.RunSnapshots{}, ErrUnavailable
	}
	if _, err := runtime.Run(ctx); err != nil {
		_ = runtime.Close()
		return session.RunSnapshots{}, fmt.Errorf("execute recovery and standard-runtime sequence: %w", err)
	}
	snapshots, err := a.Snapshots.RunSnapshots(ctx, binding)
	if err != nil {
		_ = runtime.Close()
		return session.RunSnapshots{}, fmt.Errorf("read independently-produced run snapshots: %w", err)
	}
	if err := runtime.Close(); err != nil {
		return session.RunSnapshots{}, fmt.Errorf("close run runtime coordinator: %w", err)
	}
	return snapshots, nil
}

func (a *Adapter) require() error {
	if a == nil || a.Build == nil || a.Snapshots == nil {
		return ErrUnavailable
	}
	return nil
}
