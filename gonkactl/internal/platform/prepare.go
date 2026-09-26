package platform

import (
	"context"
	"encoding/json"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type preparationHandler struct{ deps contracts.Dependencies }

func NewRoleAwarePlatformPreparationHandler(deps contracts.Dependencies) contracts.Handler {
	return preparationHandler{deps: deps}
}

func (h preparationHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var request struct {
		Role         Role `json:"role"`
		GPUSupported bool `json:"gpu_supported"`
	}
	if err := json.Unmarshal(input, &request); err != nil {
		return platformResult("invalid_input", 2), nil
	}
	role, err := ResolveRole(request.Role, request.GPUSupported)
	if err != nil {
		return platformResult("unsupported_role", 2), nil
	}
	plan, err := NewFirewallPlan(role, false)
	if err != nil || plan.Validate() != nil {
		return platformResult("platform_policy_invalid", 5), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "host prepare", Status: "planned", Phase: "plan", Code: "prepare_plan", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}

func platformResult(code string, exitCode int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "host prepare", Status: "failed", Phase: "parse", Code: code, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Host preparation input was refused.", Retryable: false}, ExitCode: exitCode}
}
