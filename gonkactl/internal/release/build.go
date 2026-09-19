package release

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type buildHandler struct{ deps contracts.Dependencies }

func NewCandidateBuildWorkflowDispatchHandler(deps contracts.Dependencies) contracts.Handler {
	return buildHandler{deps}
}
func (h buildHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var i WorkflowIntent
	if json.Unmarshal(input, &i) != nil || i.Validate() != nil {
		return buildFail("invalid_workflow_intent", 2), nil
	}
	if !i.DryRun {
		return buildFail("workflow_dispatch_requires_external_authority", 6), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "release candidate build", Status: "planned", Phase: "dispatch", Code: "workflow_dispatch_dry_run", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func buildFail(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "release candidate build", Status: "blocked", Phase: "dispatch", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Candidate workflow dispatch was not performed.", Retryable: false}, ExitCode: e}
}
