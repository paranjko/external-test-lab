package report

import (
	"os"
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
	t.Setenv("GONKACTL_TEST_INTERRUPT_AFTER_HISTORY_COMMIT", "true")
	if err := RenderTransaction(t.Context(), d, run); err == nil {
		t.Fatal("interruption was not injected")
	}
	t.Setenv("GONKACTL_TEST_INTERRUPT_AFTER_HISTORY_COMMIT", "")
	if err := RenderTransaction(t.Context(), d, run); err != nil {
		t.Fatalf("retry: %v", err)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := RenderTransaction(t.Context(), d, run); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(d, "history", "qualification-v4", "history.jsonl"))
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
	t.Setenv("GONKACTL_TEST_FORCE_RENDER_FAILURE", "true")
	if err := RenderTransaction(t.Context(), d, run); err == nil {
		t.Fatal("forced renderer failure unexpectedly succeeded")
	}
	if got, err := os.ReadFile(archive); err != nil || string(got) != string(original) {
		t.Fatalf("renderer failure altered result archive: got=%q err=%v", got, err)
	}
	scope := filepath.Join(d, "history", "qualification-v4")
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
