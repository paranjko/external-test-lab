package host

import (
	"context"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func (h lifecycleHandler) verify(ctx context.Context, input lifecycleInput) (contracts.Result, error) {
	state, err := h.inspect(ctx, input)
	if err != nil {
		return lifecycleResult("host_runtime_unavailable", "blocked", "verify", 4), nil
	}
	if len(state.Services) == 0 {
		return lifecycleResult("host_services_incomplete", "blocked", "verify", 4), nil
	}
	for _, service := range state.Services {
		if !service.Running || service.Health != "healthy" {
			return lifecycleResult("host_services_incomplete", "blocked", "verify", 4), nil
		}
	}
	result := lifecycleResult("host_local_services_verified", "completed", "verify", 0)
	result.Data.RequiresQualification = true // peer, chain, lag and UI/API proof remain separate observations.
	return result, nil
}
