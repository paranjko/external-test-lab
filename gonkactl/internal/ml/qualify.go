package ml

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type qualificationHandler struct{ deps contracts.Dependencies }

func NewRealLocalMlQualificationHandler(deps contracts.Dependencies) contracts.Handler {
	return qualificationHandler{deps}
}
func (h qualificationHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		GPUAvailable bool `json:"gpu_available"`
		VRAMMiB      int  `json:"vram_mib"`
	}
	if json.Unmarshal(input, &r) != nil {
		return mlResult("invalid_ml_input", 2), nil
	}
	d := Qwen3Descriptor()
	if !r.GPUAvailable || r.VRAMMiB < d.VRAMMiB {
		return mlResult("gpu_unsupported", 3), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "ml qualify", Status: "planned", Phase: "qualify", Code: "ml_qualification_pending_probe", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func mlResult(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "ml qualify", Status: "failed", Phase: "qualify", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Local ML qualification is unavailable.", Retryable: false}, ExitCode: e}
}
