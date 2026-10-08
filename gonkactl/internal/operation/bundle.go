package operation

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"time"
)

type bundleHandler struct{ deps contracts.Dependencies }

func NewTypedOwnerBundlesAndReceiptsHandler(deps contracts.Dependencies) contracts.Handler {
	return bundleHandler{deps}
}
func (h bundleHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		Bundle     OwnerBundle     `json:"bundle"`
		Config     json.RawMessage `json:"config"`
		BundlePath string          `json:"bundle_path"`
	}
	if json.Unmarshal(input, &r) != nil || len(r.Config) > 0 && r.BundlePath != "" || r.Bundle.Validate(time.Now().UTC()) != nil {
		return bundleResult("invalid_owner_bundle", 2), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "owner bundle", Status: "planned", Phase: "validate", Code: "owner_bundle_valid", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func bundleResult(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "owner bundle", Status: "failed", Phase: "validate", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Owner bundle was refused.", Retryable: false}, ExitCode: e}
}
