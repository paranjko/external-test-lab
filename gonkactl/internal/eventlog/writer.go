package eventlog

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type Writer struct {
	mu     sync.Mutex
	path   string
	stderr io.Writer
	seq    uint64
}

type sanitizedEventWriterHandler struct{ deps contracts.Dependencies }

func NewSanitizedEventWriterHandler(deps contracts.Dependencies) contracts.Handler {
	return sanitizedEventWriterHandler{deps: deps}
}

func (h sanitizedEventWriterHandler) Execute(ctx context.Context, input json.RawMessage) (contracts.Result, error) {
	if h.deps.Events == nil {
		return eventResult("event_sink_unavailable", 3), nil
	}
	if err := h.deps.Events.Emit(ctx, input); err != nil {
		return eventResult("audit_write_failed", 8), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "log", Status: "complete", Phase: "complete", Code: "event_written", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}

func eventResult(code string, exitCode int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "log", Status: "failed", Phase: "failed", Code: code, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Audit event could not be written.", Retryable: false}, ExitCode: exitCode}
}

func New(path string, stderr io.Writer) (*Writer, error) {
	if path == "" {
		return nil, fmt.Errorf("event log path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	return &Writer{path: path, stderr: stderr}, nil
}

func (w *Writer) Emit(raw json.RawMessage) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	clean, err := redact(raw)
	if err != nil {
		return err
	}
	var event map[string]any
	if err := json.Unmarshal(clean, &event); err != nil {
		return err
	}
	w.seq++
	event["seq"] = fmt.Sprintf("%d", w.seq)
	event["timestamp"] = time.Now().UTC().Format(time.RFC3339Nano)
	clean, err = json.Marshal(event)
	if err != nil {
		return err
	}
	clean = append(clean, '\n')
	if err := rotate(w.path); err != nil {
		return err
	}
	file, err := os.OpenFile(w.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(clean); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if w.stderr != nil {
		_, err = w.stderr.Write(clean)
	}
	return err
}
