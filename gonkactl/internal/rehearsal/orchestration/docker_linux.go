//go:build linux

package orchestration

import (
	"context"
	"fmt"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/driver"
)

// PlanBuild derives a complete runtime plan from the immutable session
// binding. It is deliberately a function rather than a caller-supplied plan:
// the resulting resource labels, mounts and binary pins are revalidated by
// driver.NewDockerCoordinator before any runtime command is issued.
type PlanBuild func(contract.RunBinding) (driver.Plan, error)

// DockerBuild is the production bridge from a verified local runtime plan to
// the native, allowlisted Docker coordinator. Hooks remain an explicit
// dependency because their Core-produced evidence format is not available in
// this repository yet; nil hooks fail before any runtime mutation.
func DockerBuild(planBuild PlanBuild, executable string, hooks driver.EvidenceHooks) Build {
	return func(binding contract.RunBinding) (Runtime, error) {
		if planBuild == nil || hooks == nil {
			return nil, ErrUnavailable
		}
		plan, err := planBuild(binding)
		if err != nil {
			return nil, fmt.Errorf("derive bound runtime plan: %w", err)
		}
		if plan.Binding.RunID != binding.RunID {
			return nil, ErrUnavailable
		}
		journal, err := driver.OpenFSJournal(binding)
		if err != nil {
			return nil, fmt.Errorf("open durable driver journal: %w", err)
		}
		coordinator, err := driver.NewDockerCoordinator(plan, executable, journal, hooks)
		if err != nil {
			_ = journal.Close()
			return nil, fmt.Errorf("compose native runtime coordinator: %w", err)
		}
		return &dockerRuntime{coordinator: coordinator, journal: journal}, nil
	}
}

type dockerRuntime struct {
	coordinator *driver.Coordinator
	journal     *driver.FSJournal
}

func (r *dockerRuntime) RunThrough(ctx context.Context, step driver.Step) error {
	if r == nil || r.coordinator == nil {
		return ErrUnavailable
	}
	return r.coordinator.RunThrough(ctx, step)
}

func (r *dockerRuntime) Run(ctx context.Context) (driver.Result, error) {
	if r == nil || r.coordinator == nil {
		return driver.Result{}, ErrUnavailable
	}
	return r.coordinator.Run(ctx)
}

func (r *dockerRuntime) Close() error {
	if r == nil || r.journal == nil {
		return nil
	}
	return r.journal.Close()
}
