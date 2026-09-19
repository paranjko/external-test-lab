package eventlog

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

type logEvent struct {
	Timestamp string          `json:"timestamp"`
	RunID     string          `json:"run_id"`
	Seq       string          `json:"seq"`
	Level     string          `json:"level"`
	Event     string          `json:"event"`
	Context   json.RawMessage `json:"context"`
	Error     json.RawMessage `json:"error"`
	Raw       json.RawMessage `json:"-"`
}

func decodeLogEvent(line []byte) (logEvent, error) {
	var event logEvent
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&event); err != nil {
		return logEvent{}, err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return logEvent{}, fmt.Errorf("trailing JSON")
	}
	if _, ok := levelRank[strings.ToUpper(event.Level)]; !ok || event.Event == "" {
		return logEvent{}, fmt.Errorf("invalid event envelope")
	}
	event.Raw = append([]byte(nil), line...)
	return event, nil
}

func formatLogEvent(event logEvent, format string) ([]byte, error) {
	switch format {
	case "json":
		return append(append([]byte(nil), event.Raw...), '\n'), nil
	case "compact":
		return []byte(fmt.Sprintf("%s %-5s %s\n", event.Timestamp, strings.ToUpper(event.Level), event.Event)), nil
	case "table":
		return []byte(fmt.Sprintf("%-30s %-5s %-24s %s\n", event.Timestamp, strings.ToUpper(event.Level), event.Event, compactContext(event.Context))), nil
	default:
		return nil, fmt.Errorf("invalid log format %q", format)
	}
}

func compactContext(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return ""
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(encoded)
}
