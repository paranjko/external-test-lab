package report

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Exercise the shell finalizer itself: an interruption after the atomic history
// commit must be recoverable and concurrent retries must remain idempotent.
func TestRenderTransactionInterruptionRetryAndConcurrency(t *testing.T) {
	d := t.TempDir()
	run := "run-transaction-test"
	results := filepath.Join(d, "report", "results", run)
	if err := os.MkdirAll(results, 0o755); err != nil {
		t.Fatal(err)
	}
	result := `{"uuid":"u1","historyId":"h1","name":"case","fullName":"feature:case","status":"passed","stage":"finished","start":1000,"stop":2000,"steps":[],"labels":[]}`
	if err := os.WriteFile(filepath.Join(results, "u1-result.json"), []byte(result), 0o644); err != nil {
		t.Fatal(err)
	}
	root, err := filepath.Abs("../build/gonkactl-test/report")
	if err != nil {
		t.Fatal(err)
	}
	_ = root
	script := filepath.Join(".", "render-transaction.sh")
	cmd := exec.Command("bash", script, d, run)
	cmd.Dir = "."
	cmd.Env = append(os.Environ(), "GONKACTL_TEST_INTERRUPT_AFTER_HISTORY_COMMIT=true")
	if err := cmd.Run(); err == nil {
		t.Fatal("interruption was not injected")
	}
	cmd = exec.Command("bash", script, d, run)
	cmd.Dir = "."
	cmd.Env = os.Environ()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("retry: %v: %s", err, out)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if out, err := exec.Command("bash", script, d, run).CombinedOutput(); err != nil {
				errs <- fmt.Errorf("concurrent retry: %w: %s", err, out)
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(d, "history", "m0-v4", "history.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(b), "\n") != 1 {
		t.Fatalf("history duplicated: %q", b)
	}
}

func TestRenderFailurePreservesResultArchiveAndAvoidsHistoryPromotion(t *testing.T) {
	d := t.TempDir()
	run := "run-render-failure"
	results := filepath.Join(d, "report", "results", run)
	if err := os.MkdirAll(results, 0o755); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(results, "u1-result.json")
	original := []byte(`{"uuid":"u1","historyId":"h1","name":"case","fullName":"feature:case","status":"passed","stage":"finished","start":1000,"stop":2000,"steps":[],"labels":[]}`)
	if err := os.WriteFile(archive, original, 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", "./render-transaction.sh", d, run)
	cmd.Dir = "."
	cmd.Env = append(os.Environ(), "GONKACTL_TEST_FORCE_RENDER_FAILURE=true")
	if err := cmd.Run(); err == nil {
		t.Fatal("forced renderer failure unexpectedly succeeded")
	}
	if got, err := os.ReadFile(archive); err != nil || string(got) != string(original) {
		t.Fatalf("renderer failure altered result archive: got=%q err=%v", got, err)
	}
	scope := filepath.Join(d, "history", "m0-v4")
	if _, err := os.Stat(filepath.Join(scope, "history.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("renderer failure promoted history: %v", err)
	}
	transaction, err := os.ReadFile(filepath.Join(scope, "transactions", run))
	if err != nil || string(transaction) != "renderer_failed:97\n" {
		t.Fatalf("failure transaction=%q err=%v", transaction, err)
	}
	if _, err := os.Stat(filepath.Join(scope, "receipts", run)); !os.IsNotExist(err) {
		t.Fatalf("renderer failure wrote a success receipt: %v", err)
	}
}
