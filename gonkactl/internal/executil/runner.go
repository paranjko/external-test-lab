// Package executil provides the sole argv-based subprocess boundary.
package executil

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

const DefaultOutputLimit int64 = 1 << 20

// Runner executes only local argv programs. It does not log stdin: callers can
// safely provide a secret reader through ProcessSpec.Stdin without it being
// copied to results or diagnostic errors.
type Runner struct {
	DefaultOutputLimit int64
}

func NewRunner() Runner { return Runner{DefaultOutputLimit: DefaultOutputLimit} }

func (r Runner) Run(ctx context.Context, spec contracts.ProcessSpec) (contracts.ProcessResult, error) {
	if err := validateSpec(spec); err != nil {
		return contracts.ProcessResult{}, err
	}
	if ctx == nil {
		return contracts.ProcessResult{}, errors.New("nil context")
	}
	if spec.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, spec.Timeout)
		defer cancel()
	}
	limit := spec.OutputLimitBytes
	if limit == 0 {
		limit = r.DefaultOutputLimit
		if limit == 0 {
			limit = DefaultOutputLimit
		}
	}
	if limit < 1 {
		return contracts.ProcessResult{}, errors.New("output limit must be positive")
	}
	cmd := exec.CommandContext(ctx, spec.Executable, spec.Args...)
	cmd.Dir = spec.Directory
	cmd.Env = append([]string(nil), spec.Env...)
	cmd.Stdin = spec.Stdin
	stdout, stderr := &boundedBuffer{limit: limit}, &boundedBuffer{limit: limit}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	result := contracts.ProcessResult{Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), Truncated: stdout.Truncated() || stderr.Truncated()}
	if cmd.ProcessState != nil {
		result.ExitCode = cmd.ProcessState.ExitCode()
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	return result, err
}

func validateSpec(spec contracts.ProcessSpec) error {
	if spec.Executable == "" || filepath.Base(spec.Executable) != spec.Executable && !filepath.IsAbs(spec.Executable) {
		return errors.New("executable must be a local command name or absolute path")
	}
	base := filepath.Base(spec.Executable)
	switch base {
	case "sh", "bash", "zsh", "fish", "ssh", "scp", "sftp":
		return fmt.Errorf("forbidden executable: %s", base)
	case "docker":
		for _, arg := range spec.Args {
			if arg == "--host" || arg == "-H" || arg == "--context" || strings.HasPrefix(arg, "--host=") || strings.HasPrefix(arg, "--context=") {
				return errors.New("remote docker invocation is forbidden")
			}
		}
	}
	for _, env := range spec.Env {
		name, _, ok := strings.Cut(env, "=")
		if !ok || name == "" || name == "DOCKER_HOST" || name == "DOCKER_CONTEXT" {
			return errors.New("invalid or remote-runtime environment entry")
		}
	}
	return nil
}

type boundedBuffer struct {
	mu        sync.Mutex
	buf       bytes.Buffer
	limit     int64
	truncated bool
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	remaining := b.limit - int64(b.buf.Len())
	if remaining <= 0 {
		b.truncated = true
		return len(p), nil
	}
	if int64(len(p)) > remaining {
		_, _ = b.buf.Write(p[:remaining])
		b.truncated = true
		return len(p), nil
	}
	_, _ = b.buf.Write(p)
	return len(p), nil
}

func (b *boundedBuffer) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]byte(nil), b.buf.Bytes()...)
}

func (b *boundedBuffer) Truncated() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.truncated
}

var _ contracts.Runner = Runner{}
var _ io.Writer = (*boundedBuffer)(nil)
var _ = time.Second
