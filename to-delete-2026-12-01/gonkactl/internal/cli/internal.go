package cli

import (
	"context"
	"encoding/json"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

// ExecuteInternalService retains the versioned domain handler boundary for the
// hidden local worker entrypoint. It never renders a buffered CLI result.
func ExecuteInternalService(ctx context.Context, handler contracts.Handler, input json.RawMessage) (contracts.Result, error) {
	return handler.Execute(ctx, input)
}
