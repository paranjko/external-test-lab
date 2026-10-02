package report

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type publishHandler struct{ deps contracts.Dependencies }

func NewExplicitGithubReportPublicationHandler(deps contracts.Dependencies) contracts.Handler {
	return publishHandler{deps}
}
func (h publishHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var p Publication
	if json.Unmarshal(input, &p) != nil || p.Validate() != nil {
		return publicationResult("publication_not_authorized", 2), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "report github publish", Status: "planned", Phase: "publishing", Code: "publication_intent_recorded", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func publicationResult(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "report github publish", Status: "failed", Phase: "validate", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "GitHub publication was not authorized.", Retryable: false}, ExitCode: e}
}
