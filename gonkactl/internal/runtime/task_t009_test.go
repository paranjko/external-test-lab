package runtime

import (
	"context"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type runner struct {
	calls int
	spec  contracts.ProcessSpec
}

func (r *runner) Run(_ context.Context, spec contracts.ProcessSpec) (contracts.ProcessResult, error) {
	r.calls++
	r.spec = spec
	return contracts.ProcessResult{}, nil
}

func TestTask_T009(t *testing.T) {
	if RequireDigest("registry/example:tag") == nil || RequireDigest("registry/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != nil {
		t.Fatal("immutable image policy")
	}
	runner := &runner{}
	runtime := NewLocalRuntime(runner)
	if err := runtime.Apply(context.Background(), "relative"); err == nil {
		t.Fatal("relative generation accepted")
	}
	if err := runtime.Apply(context.Background(), "/owned/generation"); err != nil || runner.calls != 1 || runner.spec.Executable != "docker" {
		t.Fatalf("local apply = %#v %v", runner.spec, err)
	}
}
