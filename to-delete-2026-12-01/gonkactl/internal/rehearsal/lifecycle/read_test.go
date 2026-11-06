package lifecycle

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestReadStoredSnapshotDoesNotCreateOrReconcile(t *testing.T) {
	root := filepath.Join(t.TempDir(), "run")
	if _, _, _, _, err := ReadStoredSnapshot(root); err == nil {
		t.Fatal("missing journal accepted")
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("read created workspace")
	}
	b := binding(root)
	l, err := Open(root, b)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, _, err := ReadStoredSnapshot(root); err == nil {
		t.Fatal("active writer lock ignored")
	}
	if err := l.RecordIntent("init", contract.Receipt{Phase: contract.Stage}); err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(filepath.Join(root, journalName))
	if err != nil {
		t.Fatal(err)
	}
	got, state, _, receipts, err := ReadStoredSnapshot(root)
	if err != nil {
		t.Fatal(err)
	}
	if state != contract.Unknown || got.RunID != b.RunID || len(receipts) != 1 {
		t.Fatalf("unexpected read: %s %v", state, receipts)
	}
	after, err := os.ReadFile(filepath.Join(root, journalName))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("readonly snapshot rewrote journal")
	}
}
