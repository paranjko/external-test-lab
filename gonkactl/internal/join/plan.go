package join

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type planningHandler struct{ deps contracts.Dependencies }

func NewReadOnlyJoinPlanningHandler(deps contracts.Dependencies) contracts.Handler {
	return planningHandler{deps}
}
func (h planningHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var p PlanInput
	if json.Unmarshal(input, &p) != nil || p.Validate() != nil {
		return planResult("invalid_join_plan_input", 2), nil
	}
	qualification := "unavailable"
	data := contracts.EmptyResultData()
	data.RequiresQualification = true
	data.Profile = json.RawMessage(`{"plan_digest":"` + p.Digest() + `","qualification":"` + qualification + `"}`)
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: "planned", Phase: "plan", Code: "join_plan", Mutation: "none", SignerState: "unknown", Data: data, ExitCode: 0}, nil
}
func planResult(code string, exit int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: "failed", Phase: "parse", Code: code, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "JOIN plan input was refused.", Retryable: false}, ExitCode: exit}
}
