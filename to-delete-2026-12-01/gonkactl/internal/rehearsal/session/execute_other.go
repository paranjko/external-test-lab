//go:build !linux

package session

import (
	"context"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

var errPhaseUnavailable = errors.New("persisted phase dispatch is unavailable on this platform")

func ExecuteStage(context.Context, string, string, StageAdapter) (contract.Receipt, error) {
	return contract.Receipt{}, errPhaseUnavailable
}

func ExecuteRun(context.Context, string, string, RunAdapter) (contract.Receipt, error) {
	return contract.Receipt{}, errPhaseUnavailable
}
