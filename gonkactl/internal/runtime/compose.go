package runtime

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type LocalRuntime struct{ runner contracts.Runner }

func NewLocalRuntime(runner contracts.Runner) *LocalRuntime { return &LocalRuntime{runner: runner} }

func (r *LocalRuntime) Apply(ctx context.Context, generationDir string) error {
	return r.run(ctx, generationDir, "config", "--quiet")
}
func (r *LocalRuntime) Start(ctx context.Context, generationDir string, services []string) error {
	return r.run(ctx, generationDir, append([]string{"up", "-d"}, services...)...)
}
func (r *LocalRuntime) Stop(ctx context.Context, generationDir string, services []string) error {
	return r.run(ctx, generationDir, append([]string{"stop"}, services...)...)
}
func (r *LocalRuntime) run(ctx context.Context, generationDir string, args ...string) error {
	if !filepath.IsAbs(generationDir) {
		return fmt.Errorf("generation directory must be absolute")
	}
	if r.runner == nil {
		return fmt.Errorf("local runtime runner is unavailable")
	}
	result, err := r.runner.Run(ctx, contracts.ProcessSpec{Executable: "docker", Args: append([]string{"compose", "--project-directory", generationDir}, args...), Directory: generationDir})
	if err != nil {
		return err
	}
	if result.ExitCode != 0 {
		return fmt.Errorf("local docker compose failed with exit %d", result.ExitCode)
	}
	return nil
}
