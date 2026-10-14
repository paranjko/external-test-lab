package distribution

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type distributionHandler struct{ deps contracts.Dependencies }

func NewDistributionOwnerPublicationAndRollbackHandler(deps contracts.Dependencies) contracts.Handler {
	return distributionHandler{deps}
}
func (h distributionHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		Release  string `json:"release"`
		Verified bool   `json:"verified"`
	}
	if json.Unmarshal(input, &r) != nil || r.Release == "" || !r.Verified {
		return distFail(), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "ops distribution apply", Status: "planned", Phase: "stage", Code: "distribution_release_staged", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func distFail() contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "ops distribution apply", Status: "failed", Phase: "validate", Code: "distribution_bundle_invalid", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 2}
}
