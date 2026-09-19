package host

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type lifecycleInput struct {
	Action        string   `json:"action"`
	GenerationDir string   `json:"generation_dir"`
	Services      []string `json:"services"`
}

type lifecycleHandler struct{ deps contracts.Dependencies }

func NewRetainedHostRuntimeLifecycleHandler(deps contracts.Dependencies) contracts.Handler {
	return lifecycleHandler{deps: deps}
}

func (h lifecycleHandler) Execute(ctx context.Context, raw json.RawMessage) (contracts.Result, error) {
	var input lifecycleInput
	if err := json.Unmarshal(raw, &input); err != nil || input.GenerationDir == "" {
		return lifecycleResult("invalid_host_lifecycle_input", "failed", "parse", 2), nil
	}
	switch input.Action {
	case "status":
		return h.status(ctx, input)
	case "start":
		return h.start(ctx, input)
	case "stop":
		return h.stop(ctx, input)
	case "verify":
		return h.verify(ctx, input)
	default:
		return lifecycleResult("invalid_host_lifecycle_action", "failed", "parse", 2), nil
	}
}

func (h lifecycleHandler) inspect(ctx context.Context, input lifecycleInput) (contracts.RuntimeState, error) {
	if h.deps.Runtime == nil {
		return contracts.RuntimeState{}, errors.New("local runtime is unavailable")
	}
	return h.deps.Runtime.Inspect(ctx, input.GenerationDir)
}

func lifecycleResult(code, status, phase string, exit int) contracts.Result {
	data := contracts.EmptyResultData()
	data.RequiresQualification = status != "completed"
	return contracts.Result{SchemaVersion: 1, Command: "host lifecycle", Status: status, Phase: phase, Code: code, Mutation: "none", SignerState: "unknown", Data: data, ExitCode: exit}
}

func (h lifecycleHandler) status(ctx context.Context, input lifecycleInput) (contracts.Result, error) {
	state, err := h.inspect(ctx, input)
	if err != nil {
		return lifecycleResult("host_runtime_unavailable", "blocked", "status", 4), nil
	}
	data := contracts.EmptyResultData()
	data.RequiresQualification = true
	data.Profile, _ = json.Marshal(map[string]any{"generation_id": state.GenerationID, "service_abi": state.ServiceABI, "services": state.Services})
	return contracts.Result{SchemaVersion: 1, Command: "host status", Status: "planned", Phase: "status", Code: "host_status_observed", Mutation: "none", SignerState: "unknown", Data: data, ExitCode: 0}, nil
}
