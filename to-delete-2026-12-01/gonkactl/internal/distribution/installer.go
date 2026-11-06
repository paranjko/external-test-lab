package distribution

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewAtomicStandaloneInstallerHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var a Asset
	if json.Unmarshal(input, &a) != nil || a.Validate() != nil {
		return fail(), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "distribution install", Status: "planned", Phase: "install", Code: "installer_plan_valid", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func fail() contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "distribution install", Status: "failed", Phase: "validate", Code: "installer_manifest_invalid", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 2}
}
