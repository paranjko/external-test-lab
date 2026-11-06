package host

import (
	"context"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func (h lifecycleHandler) stop(ctx context.Context, input lifecycleInput) (contracts.Result, error) {
	if _, err := h.inspect(ctx, input); err != nil {
		return lifecycleResult("host_runtime_unavailable", "blocked", "stop", 4), nil
	}
	if err := h.deps.Runtime.Stop(ctx, input.GenerationDir, input.Services); err != nil {
		return lifecycleResult("host_stop_failed", "failed", "stop", 4), nil
	}
	return lifecycleResult("host_stopped", "completed", "stop", 0), nil
}
