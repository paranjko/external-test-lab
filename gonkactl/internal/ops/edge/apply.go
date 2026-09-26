package edge

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewSingleListenerEdgeDeploymentHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		Routes    []Route `json:"routes"`
		Listeners int     `json:"listeners"`
	}
	if json.Unmarshal(input, &r) != nil || r.Listeners != 1 || ValidateRoutes(r.Routes) != nil {
		return result("invalid_edge_routes", 2), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "ops edge apply", Status: "planned", Phase: "stage", Code: "edge_listener_staged", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func result(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "ops edge apply", Status: "failed", Phase: "validate", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Edge configuration was refused.", Retryable: false}, ExitCode: e}
}
