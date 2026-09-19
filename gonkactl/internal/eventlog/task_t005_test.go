package eventlog

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestTask_T005(t *testing.T) {
	var stderr bytes.Buffer
	path := filepath.Join(t.TempDir(), "audit", "events.ndjson")
	writer, err := New(path, &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Emit([]byte(`{"event":"checkpoint","context":{"height":"7","secret":"SECRET_CANARY","token":"abc"}}`)); err != nil {
		t.Fatal(err)
	}
	file, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(file, []byte("SECRET_CANARY")) || bytes.Contains(stderr.Bytes(), []byte("SECRET_CANARY")) || bytes.Contains(file, []byte("\"token\"")) {
		t.Fatalf("secret leaked: %s", file)
	}
	if !bytes.Contains(file, []byte(`"seq":"1"`)) || !bytes.Contains(file, []byte(`"timestamp"`)) {
		t.Fatalf("missing envelope fields: %s", file)
	}
}

func FuzzSecretRedaction(f *testing.F) {
	f.Add("SECRET_CANARY")
	f.Add("Bearer token")
	f.Fuzz(func(t *testing.T, value string) {
		out, err := redact([]byte(`{"event":"checkpoint","context":{"height":"7","secret":"` + value + `"}}`))
		if err != nil {
			return
		}
		if bytes.Contains(bytes.ToLower(out), []byte("secret")) {
			t.Fatalf("secret field leaked: %s", out)
		}
	})
}
