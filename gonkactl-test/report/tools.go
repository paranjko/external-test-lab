package report

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

func toolDir() (string, error) {
	if configured := os.Getenv("GONKACTL_TEST_REPORT_DIR"); configured != "" {
		info, err := os.Stat(configured)
		if err != nil {
			return "", fmt.Errorf("read GONKACTL_TEST_REPORT_DIR: %w", err)
		}
		if !info.IsDir() {
			return "", fmt.Errorf("GONKACTL_TEST_REPORT_DIR is not a directory: %s", configured)
		}
		return configured, nil
	}
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		return "", errors.New("locate report tools")
	}
	return filepath.Dir(source), nil
}

// RenderAllure renders an existing Allure results directory without changing
// qualification history. It is used for release evidence, whose results are
// already durable and must not be mixed into a qualification history stream.
func RenderAllure(ctx context.Context, results, output string) error {
	dir, err := toolDir()
	if err != nil {
		return err
	}
	if results == "" || output == "" {
		return errors.New("Allure results and output paths are required")
	}
	cmd := exec.CommandContext(ctx, filepath.Join(dir, "node_modules", ".bin", "allure"), "generate", "--config", "allurerc.mjs", results)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GONKACTL_TEST_REPORT_OUTPUT="+output, "GONKACTL_TEST_APPEND_HISTORY=false")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("render Allure report: %w", err)
	}
	if _, err := os.Stat(filepath.Join(output, "awesomeBDD", "index.html")); err != nil {
		return fmt.Errorf("rendered Allure awesomeBDD report: %w", err)
	}
	return nil
}

func runTool(ctx context.Context, dir string, args ...string) error {
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func profile(root string) (string, error) {
	p := filepath.Join(root, "profiles", fmt.Sprintf("%s-%d", time.Now().UTC().Format("20060102T150405Z"), os.Getpid()))
	return p, os.MkdirAll(p, 0o755)
}

// BrowserProbe runs the host browser check with an owned persistent profile.
func BrowserProbe(ctx context.Context, dataRoot string) error {
	dir, err := toolDir()
	if err != nil {
		return err
	}
	root := filepath.Join(dataRoot, "report", "browser-probe")
	p, err := profile(root)
	if err != nil {
		return err
	}
	return runTool(ctx, dir, "node", filepath.Join(dir, "browser-check.mjs"), "--probe", "--evidence-dir", root, "--profile", p)
}

func hasAsset(root string) (bool, error) {
	found := false
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		if strings.HasSuffix(path, ".js") || strings.HasSuffix(path, ".css") {
			found = true
		}
		return nil
	})
	return found, err
}

func requireHTTP(ctx context.Context, url string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}
	_, err = io.Copy(io.Discard, resp.Body)
	return err
}

func verifyResults(results string) error {
	entries, err := os.ReadDir(results)
	if err != nil {
		return err
	}
	count := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), "-result.json") {
			continue
		}
		count++
		b, err := os.ReadFile(filepath.Join(results, e.Name()))
		if err != nil {
			return err
		}
		s := string(b)
		if !strings.Contains(s, `"steps": [`) || !strings.Contains(s, `"attachments": [`) {
			return fmt.Errorf("result %s lacks steps or attachments", e.Name())
		}
		if strings.Contains(s, `"start": 0`) || strings.Contains(s, `"stop": 0`) {
			return fmt.Errorf("zero placeholder timing in %s", e.Name())
		}
	}
	if count != 4 {
		return fmt.Errorf("result count=%d, want 4", count)
	}
	return nil
}

// BrowserSmoke serves an immutable generated report, verifies required files,
// then delegates CDP assertions to the retained Node implementation.
func BrowserSmoke(ctx context.Context, dataRoot, runID, reportRoot string) error {
	if reportRoot == "" {
		reportRoot = filepath.Join(dataRoot, "report", "render", runID)
	}
	dir, err := toolDir()
	if err != nil {
		return err
	}
	browserRoot := filepath.Join(dataRoot, "report", "browser-smoke")
	p, err := profile(browserRoot)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	server := &http.Server{Handler: http.FileServer(http.Dir(reportRoot))}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	defer func() { _ = server.Shutdown(context.Background()); <-done }()
	base := "http://" + listener.Addr().String()
	for _, path := range []string{"awesomeBDD/index.html", "dashboard/index.html", "csv/report.csv"} {
		if err := requireHTTP(ctx, base+"/"+path); err != nil {
			return err
		}
	}
	if ok, err := hasAsset(filepath.Join(reportRoot, "awesomeBDD")); err != nil {
		return err
	} else if !ok {
		return errors.New("awesomeBDD has no JS or CSS asset")
	}
	if err := verifyResults(filepath.Join(dataRoot, "report", "results", runID)); err != nil {
		return err
	}
	return runTool(ctx, dir, "node", filepath.Join(dir, "browser-check.mjs"), "--url", base+"/awesomeBDD/index.html", "--bundle", filepath.Join(reportRoot, "awesomeBDD"), "--evidence-dir", browserRoot, "--profile", p)
}

func atomicWriteText(path, value string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(value), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RenderTransaction renders once and atomically promotes its history point.
func RenderTransaction(ctx context.Context, dataRoot, runID string) error {
	dir, err := toolDir()
	if err != nil {
		return err
	}
	scope := os.Getenv("GONKACTL_TEST_HISTORY_SCOPE")
	if scope == "" {
		scope = filepath.Join(dataRoot, "history", "qualification-v4")
	}
	history, receipt := filepath.Join(scope, "history.jsonl"), filepath.Join(scope, "receipts", runID)
	transaction, staging := filepath.Join(scope, "transactions", runID), filepath.Join(scope, "staging", runID+".history.jsonl")
	if err := os.MkdirAll(filepath.Dir(receipt), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(transaction), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(staging), 0o755); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(scope, "scope.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	if _, err := os.Stat(receipt); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if b, err := os.ReadFile(transaction); err == nil && string(b) == "history_committed\n" {
		return atomicWriteText(receipt, "recovered_after_history_commit\n")
	}
	if err := atomicWriteText(transaction, "prepared\n"); err != nil {
		return err
	}
	if b, err := os.ReadFile(history); err == nil {
		if err := os.WriteFile(staging, b, 0o600); err != nil {
			return err
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(staging, nil, 0o600); err != nil {
			return err
		}
	} else {
		return err
	}
	if os.Getenv("GONKACTL_TEST_FORCE_RENDER_FAILURE") == "true" {
		_ = atomicWriteText(transaction, "renderer_failed:97\n")
		return errors.New("renderer failed: 97")
	}
	cmd := exec.CommandContext(ctx, filepath.Join(dir, "node_modules", ".bin", "allure"), "generate", "--config", "allurerc.mjs", filepath.Join(dataRoot, "report", "results", runID))
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GONKACTL_TEST_REPORT_OUTPUT="+filepath.Join(dataRoot, "report", "render", runID), "GONKACTL_TEST_HISTORY_PATH="+staging, "GONKACTL_TEST_APPEND_HISTORY=false")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		_ = atomicWriteText(transaction, "renderer_failed:1\n")
		return err
	}
	if err := runTool(ctx, dir, "node", filepath.Join(dir, "history-append.mjs"), filepath.Join(dataRoot, "report", "render", runID), staging); err != nil {
		return err
	}
	if err := os.Rename(staging, history); err != nil {
		return err
	}
	if err := atomicWriteText(transaction, "history_committed\n"); err != nil {
		return err
	}
	if os.Getenv("GONKACTL_TEST_INTERRUPT_AFTER_HISTORY_COMMIT") == "true" {
		return errors.New("injected interruption after history commit")
	}
	return atomicWriteText(receipt, "committed\n")
}
