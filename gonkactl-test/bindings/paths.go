package bindings

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var persistentEnv = []string{"TMPDIR", "TMP", "TEMP", "GOTMPDIR", "GOCACHE", "GOMODCACHE", "NPM_CONFIG_CACHE", "XDG_CACHE_HOME", "PLAYWRIGHT_BROWSERS_PATH"}
var persistentDir = map[string]string{"TMPDIR": "tmp", "TMP": "tmp", "TEMP": "tmp", "GOTMPDIR": "go-tmp", "GOCACHE": "go-cache", "GOMODCACHE": "go-mod-cache", "NPM_CONFIG_CACHE": "npm-cache", "XDG_CACHE_HOME": "xdg-cache", "PLAYWRIGHT_BROWSERS_PATH": "browser-cache"}

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
