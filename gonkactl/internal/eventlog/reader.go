package eventlog

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

const maxLogLineBytes = 1 << 20

type LogReaderInput struct {
	Path      string   `json:"path"`
	Follow    bool     `json:"follow"`
	Level     string   `json:"level"`
	OnlyLevel []string `json:"only_level"`
	Failed    bool     `json:"failed"`
	Format    string   `json:"format"`
	TTY       bool     `json:"tty"`
}

type logReaderHandler struct {
	deps  contracts.Dependencies
	stdin io.Reader
	wait  func(context.Context, time.Duration) error
}

func NewLogReaderHandler(deps contracts.Dependencies) contracts.StreamingHandler {
	return logReaderHandler{deps: deps, stdin: os.Stdin, wait: waitForLogPoll}
}

func waitForLogPoll(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (h logReaderHandler) Stream(ctx context.Context, raw json.RawMessage, out io.Writer) error {
	if out == nil {
		return errors.New("log output writer is required")
	}
	var input LogReaderInput
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return fmt.Errorf("invalid log input: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("invalid log input: trailing document")
	}
	filter, err := newLogFilter(input.Level, input.OnlyLevel, input.Failed)
	if err != nil {
		return err
	}
	if input.Format == "" {
		if input.TTY {
			input.Format = "table"
		} else {
			input.Format = "compact"
		}
	}
	if input.Format != "table" && input.Format != "compact" && input.Format != "json" {
		return fmt.Errorf("invalid log format %q", input.Format)
	}

	path, useStdin, err := h.resolve(input.Path)
	if err != nil {
		return err
	}
	if useStdin {
		if input.Follow {
			// Pipes have a finite producer: follow means read through EOF, not wait forever.
		}
		return renderLogReader(ctx, h.stdin, out, filter, input.Format)
	}
	return h.readFile(ctx, path, input.Follow, out, filter, input.Format)
}

func (h logReaderHandler) resolve(explicit string) (string, bool, error) {
	if explicit == "-" {
		return "", true, nil
	}
	if explicit != "" {
		if !filepath.IsAbs(explicit) {
			return "", false, fmt.Errorf("log path must be absolute")
		}
		return explicit, false, nil
	}
	if file, ok := h.stdin.(*os.File); ok {
		if info, err := file.Stat(); err == nil && (info.Mode().IsRegular() || info.Mode()&os.ModeNamedPipe != 0) {
			return "", true, nil
		}
	}
	return "/var/log/gonka/gonkactl.ndjson", false, nil
}

func (h logReaderHandler) readFile(ctx context.Context, path string, follow bool, out io.Writer, filter logFilter, format string) error {
	var offset int64
	for {
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		if _, err = file.Seek(offset, io.SeekStart); err == nil {
			err = renderLogReader(ctx, file, out, filter, format)
		}
		info, statErr := file.Stat()
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if statErr != nil {
			return statErr
		}
		if closeErr != nil {
			return closeErr
		}
		offset = info.Size()
		if !follow {
			return nil
		}
		if err := h.wait(ctx, 500*time.Millisecond); err != nil {
			return err
		}
		current, err := os.Stat(path)
		if err != nil {
			return err
		}
		if current.Size() < offset {
			offset = 0
		}
	}
}

func renderLogReader(ctx context.Context, reader io.Reader, out io.Writer, filter logFilter, format string) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), maxLogLineBytes)
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		event, err := decodeLogEvent(scanner.Bytes())
		if err != nil {
			continue
		}
		if !filter.accepts(event.Level) {
			continue
		}
		line, err := formatLogEvent(event, format)
		if err != nil {
			return err
		}
		if _, err := out.Write(line); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read log: %w", err)
	}
	return nil
}
