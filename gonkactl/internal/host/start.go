package host

import (
	"context"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/identity"
)

func (h lifecycleHandler) start(ctx context.Context, input lifecycleInput) (contracts.Result, error) {
	guard, _, err := identity.ReadGuard(ctx, h.deps.Store)
	if err != nil || guard.AllowsStart() != nil {
		return lifecycleResult("signer_guard_refused", "blocked", "start", 3), nil
	}
	if _, err := h.inspect(ctx, input); err != nil {
		return lifecycleResult("host_runtime_unavailable", "blocked", "start", 4), nil
	}
	if err := h.deps.Runtime.Start(ctx, input.GenerationDir, input.Services); err != nil {
		return lifecycleResult("host_start_failed", "failed", "start", 4), nil
	}
	return lifecycleResult("host_started", "completed", "start", 0), nil
}
