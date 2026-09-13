package report

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestHistoryRecoveryAndConcurrentFinalizers(t *testing.T) {
	d := t.TempDir()
	h := filepath.Join(d, "history.jsonl")
	r := filepath.Join(d, "receipt")
	tx := filepath.Join(d, "transaction.json")
	p := HistoryPoint{ExecutionID: "exec-1", ProtocolHistoryID: "protocol-1", EvidenceHistoryID: "evidence-1", RunID: "run-1"}
	if err := PromoteHistory(h, r, tx, p, true); err == nil {
		t.Fatal("interruption was not injected")
	}
	if err := PromoteHistory(h, r, tx, p, false); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); errs <- PromoteHistory(h, r, tx, p, false) }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	b, err := os.ReadFile(h)
	if err != nil {
		t.Fatal(err)
	}
	lines := 0
	for _, c := range b {
		if c == '\n' {
			lines++
		}
	}
	if lines != 1 {
		t.Fatalf("history points=%d, want 1: %s", lines, b)
	}
	if b, err := os.ReadFile(r); err != nil || string(b) != "recovered-after-history-commit\n" {
		t.Fatalf("receipt=%q err=%v", b, err)
	}
}
