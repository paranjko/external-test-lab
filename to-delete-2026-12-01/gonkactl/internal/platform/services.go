package platform

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type internalServiceRequest struct {
	Action     string `json:"action"`
	Instance   string `json:"instance"`
	BinaryPath string `json:"binary_path"`
	Version    string `json:"version"`
	ServiceABI int    `json:"service_abi"`
}

type internalServiceHandler struct{ deps contracts.Dependencies }

func NewVersionedInternalServiceExecutionHandler(deps contracts.Dependencies) contracts.Handler {
	return internalServiceHandler{deps: deps}
}

func (h internalServiceHandler) Execute(ctx context.Context, input json.RawMessage) (contracts.Result, error) {
	var request internalServiceRequest
	if err := json.Unmarshal(input, &request); err != nil {
		return internalServiceResult("invalid_internal_service_input", "parse", "none", 2), nil
	}
	if request.ServiceABI != SupportedServiceABI {
		return internalServiceResult("unsupported_service_abi", "preflight", "none", 3), nil
	}
	if request.Action != "upgrade-worker" && request.Action != "advance-after-upgrade-worker" {
		return internalServiceResult("unsupported_internal_service_action", "parse", "none", 2), nil
	}
	if request.Instance == "" || request.Version == "" || !filepath.IsAbs(request.BinaryPath) {
		return internalServiceResult("invalid_internal_service_input", "parse", "none", 2), nil
	}
	if _, err := RenderUnit(ServiceUnit{Name: request.Action, BinaryPath: request.BinaryPath, Instance: request.Instance, ServiceABI: request.ServiceABI, Args: []string{request.Action}}); err != nil {
		return internalServiceResult("invalid_service_binary", "preflight", "none", 3), nil
	}
	if err := ctx.Err(); err != nil {
		return internalServiceResult("internal_service_cancelled", "cancelled", "none", 130), nil
	}
	// Worker effects are intentionally delegated only through the explicit local
	// Runner boundary. No shell, inherited environment, or remote controller is used.
	if h.deps.Runner == nil {
		return internalServiceResult("internal_service_runner_unavailable", "preflight", "none", 3), nil
	}
	_, err := h.deps.Runner.Run(ctx, contracts.ProcessSpec{Executable: request.BinaryPath, Args: []string{"internal", request.Action}, Directory: h.deps.Root, Timeout: 6 * 60 * 60})
	if err != nil {
		return internalServiceResult("internal_service_execution_failed", "execute", "unknown", 8), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "internal service", Status: "complete", Phase: "complete", Code: "internal_service_complete", Mutation: "local", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}

func internalServiceResult(code, phase, mutation string, exitCode int) contracts.Result {
	status := "failed"
	if phase == "cancelled" {
		status = "cancelled"
	}
	return contracts.Result{SchemaVersion: 1, Command: "internal service", Status: status, Phase: phase, Code: code, Mutation: mutation, SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Internal service request was refused or failed.", Retryable: false}, ExitCode: exitCode}
}

func (h internalServiceHandler) String() string {
	return fmt.Sprintf("internal service handler for %s", h.deps.Root)
}
