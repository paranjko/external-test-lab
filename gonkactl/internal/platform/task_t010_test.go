package platform

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func TestTask_T010(t *testing.T) {
	if _, err := RenderUnit(ServiceUnit{Name: "worker", BinaryPath: "/usr/local/lib/gonkactl/1.0.0/gonkactl", Instance: "node-1", ServiceABI: 1, Args: []string{"upgrade-worker"}}); err != nil {
		t.Fatal(err)
	}
	h := NewVersionedInternalServiceExecutionHandler(contracts.Dependencies{})
	input, _ := json.Marshal(map[string]any{"action": "upgrade-worker", "instance": "node-1", "binary_path": "/usr/local/lib/gonkactl/1.0.0/gonkactl", "version": "1.0.0", "service_abi": 2})
	result, err := h.Execute(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	if result.Code != "unsupported_service_abi" || result.ExitCode != 3 {
		t.Fatalf("unexpected ABI refusal: %#v", result)
	}
}
