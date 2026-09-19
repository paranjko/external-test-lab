package runtime

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func (r *LocalRuntime) Inspect(ctx context.Context, generationDir string) (contracts.RuntimeState, error) {
	if !filepath.IsAbs(generationDir) {
		return contracts.RuntimeState{}, fmt.Errorf("generation directory must be absolute")
	}
	if r.runner == nil {
		return contracts.RuntimeState{}, fmt.Errorf("local runtime runner is unavailable")
	}
	result, err := r.runner.Run(ctx, contracts.ProcessSpec{Executable: "docker", Args: []string{"compose", "--project-directory", generationDir, "ps", "--format", "json"}, Directory: generationDir})
	if err != nil {
		return contracts.RuntimeState{}, err
	}
	if result.ExitCode != 0 {
		return contracts.RuntimeState{}, fmt.Errorf("local docker compose inspect failed")
	}
	return contracts.RuntimeState{}, nil
}
