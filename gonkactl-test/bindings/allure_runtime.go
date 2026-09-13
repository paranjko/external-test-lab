package bindings

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	allureruntime "github.com/allure-framework/allure-go/commons/runtime"
)

// AllureEventJournal persists the official Allure Go SDK messages emitted by
// a runner. It is evidence of the adapter bridge, not a replacement for the
// generated Allure result artifacts produced by the report converter.
type AllureEventJournal struct {
	mu      sync.Mutex
	file    *os.File
	encoder *json.Encoder
	closed  bool
}

func NewAllureEventJournal(path string) (*AllureEventJournal, error) {
	if path == "" {
		return nil, fmt.Errorf("Allure event journal path is required")
	}
	if err := ValidatePersistentPath(path); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create Allure event journal: %w", err)
	}
	return &AllureEventJournal{file: f, encoder: json.NewEncoder(f)}, nil
}

func (j *AllureEventJournal) Handle(_ context.Context, message allureruntime.Message) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return fmt.Errorf("Allure event journal is closed")
	}
	if err := j.encoder.Encode(message); err != nil {
		return fmt.Errorf("encode Allure SDK message: %w", err)
	}
	if err := j.file.Sync(); err != nil {
		return fmt.Errorf("sync Allure SDK message: %w", err)
	}
	return nil
}

func (j *AllureEventJournal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return nil
	}
	j.closed = true
	return j.file.Close()
}
