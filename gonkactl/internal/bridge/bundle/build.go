package bundle

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewPinnedBridgeContractBuildBundleHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var m Manifest
	if json.Unmarshal(input, &m) != nil || Verify(m) != nil {
		return fail("bridge_bundle_unavailable", 4), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "bridge contract deploy sepolia", Status: "planned", Phase: "verify", Code: "bridge_bundle_verified", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func fail(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "bridge contract deploy sepolia", Status: "blocked", Phase: "verify", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Pinned bridge bundle is unavailable.", Retryable: false}, ExitCode: e}
}
