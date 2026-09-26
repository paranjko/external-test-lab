package recovery

import (
	"context"
	"encoding/json"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewT080Handler(deps contracts.Dependencies) contracts.Handler { return handler{deps: deps} }

func (h handler) Execute(_ context.Context, raw json.RawMessage) (contracts.Result, error) {
	var input Input
	if json.Unmarshal(raw, &input) != nil || h.deps.Validator == nil || h.deps.Validator.Validate(ManifestSchema, input.Manifest) != nil || h.deps.Validator.Validate(PhaseProofSchema, input.Proof) != nil {
		return result("recovery_contract_refused", "blocked", 3), nil
	}
	return result("recovery_contract_validated", "planned", 0), nil
}

func result(code, status string, exit int) contracts.Result {
	data := contracts.EmptyResultData()
	data.RequiresQualification = true
	return contracts.Result{SchemaVersion: 1, Command: "network recover status", Status: status, Phase: "recover", Code: code, Mutation: "none", SignerState: "unknown", Data: data, ExitCode: exit}
}
