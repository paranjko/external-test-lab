package bindings

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

var persistentEnv = []string{"TMPDIR", "TMP", "TEMP", "GOTMPDIR", "GOCACHE", "GOMODCACHE", "NPM_CONFIG_CACHE", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "PLAYWRIGHT_BROWSERS_PATH", "HOME"}
var persistentDir = map[string]string{"TMPDIR": "tmp", "TMP": "tmp", "TEMP": "tmp", "GOTMPDIR": "go-tmp", "GOCACHE": "go-cache", "GOMODCACHE": "go-mod-cache", "NPM_CONFIG_CACHE": "npm-cache", "XDG_CACHE_HOME": "xdg-cache", "XDG_CONFIG_HOME": "xdg-config", "PLAYWRIGHT_BROWSERS_PATH": "browser-cache", "HOME": "child-home"}

func ValidatePersistentPath(path string) error {
	if path == "" || !filepath.IsAbs(path) {
		return fmt.Errorf("persistent path must be absolute: %q", path)
	}
	resolved, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if err == nil {
		path = filepath.Join(resolved, filepath.Base(path))
	}
	clean := filepath.Clean(path)
	for _, bad := range []string{"/tmp", "/var/tmp"} {
		if clean == bad || strings.HasPrefix(clean, bad+string(filepath.Separator)) {
			return fmt.Errorf("forbidden temporary path: %s", clean)
		}
	}
	return nil
}
func PersistentEnvironment(root string) ([]string, error) {
	if err := ValidatePersistentPath(filepath.Join(root, "probe")); err != nil {
		return nil, err
	}
	var env []string
	for _, key := range persistentEnv {
		p := filepath.Join(root, persistentDir[key])
		if err := os.MkdirAll(p, 0o755); err != nil {
			return nil, err
		}
		env = append(env, key+"="+p)
	}
	return env, nil
}

// ValidateChildReportedPaths checks effective paths reported by a launched
// child. Environment injection alone is insufficient because a child may
// ignore it or hardcode a system temporary directory.
func ValidateChildReportedPaths(root string, reported map[string]string) error {
	rootResolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	for _, key := range persistentEnv {
		raw, ok := reported[key]
		if !ok {
			return fmt.Errorf("child did not report %s", key)
		}
		if err := ValidatePersistentPath(filepath.Join(raw, "probe")); err != nil {
			return fmt.Errorf("child %s: %w", key, err)
		}
		resolved, err := filepath.EvalSymlinks(raw)
		if err != nil {
			return fmt.Errorf("resolve child %s: %w", key, err)
		}
		rel, err := filepath.Rel(rootResolved, resolved)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Errorf("child %s escaped persistent root: %s", key, resolved)
		}
	}
	return nil
}

type ChildEnvironmentReceipt struct {
	Command    []string          `json:"command"`
	Reported   map[string]string `json:"reported"`
	ExitCode   int               `json:"exit_code"`
	Valid      bool              `json:"valid"`
	RecordedAt string            `json:"recorded_at"`
}

// ProbeChildEnvironment launches a real child, validates the paths it reports,
// and retains the observation under the owned persistent root.
func ProbeChildEnvironment(ctx context.Context, root, command string, args ...string) (string, error) {
	env, err := PersistentEnvironment(root)
	if err != nil {
		return "", err
	}
	cmd := exec.CommandContext(ctx, command, args...)
	cmd.Env = append(os.Environ(), env...)
	out, runErr := cmd.Output()
	reported := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			reported[key] = value
		}
	}
	validationErr := ValidateChildReportedPaths(root, reported)
	receipt := ChildEnvironmentReceipt{
		Command: append([]string{command}, args...), Reported: reported,
		ExitCode: -1, Valid: runErr == nil && validationErr == nil,
		RecordedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	if cmd.ProcessState != nil {
		receipt.ExitCode = cmd.ProcessState.ExitCode()
	}
	receiptDir := filepath.Join(root, "child-environment-receipts")
	if err := os.MkdirAll(receiptDir, 0o755); err != nil {
		return "", err
	}
	encoded, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return "", err
	}
	receiptPath := filepath.Join(receiptDir, fmt.Sprintf("%d-%d.json", os.Getpid(), time.Now().UnixNano()))
	if err := os.WriteFile(receiptPath, append(encoded, '\n'), 0o600); err != nil {
		return "", err
	}
	if runErr != nil {
		return receiptPath, fmt.Errorf("environment probe child: %w", runErr)
	}
	if validationErr != nil {
		return receiptPath, validationErr
	}
	return receiptPath, nil
}
