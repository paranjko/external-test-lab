package host

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type runtimeStub struct {
	state            contracts.RuntimeState
	started, stopped bool
}

func (r *runtimeStub) Inspect(context.Context, string) (contracts.RuntimeState, error) {
	return r.state, nil
}
func (r *runtimeStub) Apply(context.Context, string) error           { return nil }
func (r *runtimeStub) Start(context.Context, string, []string) error { r.started = true; return nil }
func (r *runtimeStub) Stop(context.Context, string, []string) error  { r.stopped = true; return nil }

func TestTask_T025(t *testing.T) {
	runtime := &runtimeStub{state: contracts.RuntimeState{GenerationID: "g1", ServiceABI: 1, Services: []contracts.ServiceState{{Name: "core", Running: true, Health: "healthy"}}}}
	h := NewRetainedHostRuntimeLifecycleHandler(contracts.Dependencies{Runtime: runtime})
	for _, action := range []string{"status", "verify", "stop"} {
		raw, _ := json.Marshal(lifecycleInput{Action: action, GenerationDir: "/var/lib/gonkactl/g1", Services: []string{"core"}})
		result, err := h.Execute(context.Background(), raw)
		if err != nil || result.ExitCode != 0 {
			t.Fatalf("%s: %#v %v", action, result, err)
		}
	}
	if !runtime.stopped {
		t.Fatal("stop was not delegated to local runtime")
	}
	raw, _ := json.Marshal(lifecycleInput{Action: "start", GenerationDir: "/var/lib/gonkactl/g1"})
	result, err := h.Execute(context.Background(), raw)
	if err != nil || result.Code != "signer_guard_refused" {
		t.Fatalf("unguarded start: %#v %v", result, err)
	}
}
