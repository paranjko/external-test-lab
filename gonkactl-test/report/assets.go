package report

import (
	"context"
	"crypto/sha256"
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

//go:embed allurerc.mjs browser-check.mjs history-append.mjs package.json package-lock.json
var releaseAssets embed.FS

// Bundled tools are keyed by their content, so upgrading the binary cannot
// silently reuse a renderer installed for another dependency lock.
func bundledToolDir() (string, error) {
	entries, err := releaseAssets.ReadDir(".")
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	for _, entry := range entries {
		data, err := releaseAssets.ReadFile(entry.Name())
		if err != nil {
			return "", err
		}
		fmt.Fprintf(hash, "%s\x00%d\x00", entry.Name(), len(data))
		hash.Write(data)
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(cache, "gonkactl-test", fmt.Sprintf("report-%x", hash.Sum(nil)))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	lock, err := os.OpenFile(filepath.Join(dir, ".assets.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return "", err
	}
	defer lock.Close()
	if err := lockFile(lock); err != nil {
		return "", err
	}
	defer unlockFile(lock)
	for _, entry := range entries {
		data, err := releaseAssets.ReadFile(entry.Name())
		if err != nil {
			return "", err
		}
		path := filepath.Join(dir, entry.Name())
		if existing, err := os.ReadFile(path); err == nil && string(existing) == string(data) {
			continue
		}
		if err := atomicWrite(path, data, 0o600); err != nil {
			return "", err
		}
	}
	return dir, nil
}

// SetupReport explicitly installs the pinned renderer. Ordinary CLI startup,
// --help and --version never download dependencies.
func SetupReport(ctx context.Context) error {
	dir, err := toolDir()
	if err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		return runTool(ctx, dir, "cmd.exe", "/d", "/c", "npm ci --ignore-scripts --no-audit --no-fund")
	}
	return runTool(ctx, dir, "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund")
}
