package network

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type observationHandler struct{ deps contracts.Dependencies }

func NewSoftwareAndLineageObservationHandler(deps contracts.Dependencies) contracts.Handler {
	return observationHandler{deps}
}
func (h observationHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var request struct {
		ChainID      string        `json:"chain_id"`
		Observations []Observation `json:"observations"`
	}
	if json.Unmarshal(input, &request) != nil {
		return observeResult("invalid_observation_input", 2), nil
	}
	if _, err := SelectRuntime(request.Observations, request.ChainID); err != nil {
		return observeResult("runtime_quorum_unavailable", 4), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: "planned", Phase: "observe", Code: "runtime_observed", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func observeResult(code string, exit int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: "failed", Phase: "observe", Code: code, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Network observation could not establish a quorum.", Retryable: true}, ExitCode: exit}
}
