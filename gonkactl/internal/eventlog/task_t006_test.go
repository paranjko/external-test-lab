package eventlog

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func TestTask_T006(t *testing.T) {
	input := []byte(`{"path":"-","level":"DEBUG","only_level":["INFO,ERROR"],"format":"json"}`)
	var output bytes.Buffer
	h := logReaderHandler{stdin: strings.NewReader("{bad}\n{\"timestamp\":\"2026-09-11T00:00:00Z\",\"run_id\":\"r\",\"seq\":\"1\",\"level\":\"ERROR\",\"event\":\"failed\",\"context\":{},\"error\":null}\n"), wait: waitForLogPoll}
	if err := h.Stream(context.Background(), input, &output); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); !strings.Contains(got, `"level":"ERROR"`) || strings.Contains(got, "DEBUG") {
		t.Fatalf("unexpected filtered output %q", got)
	}
	if _, err := newLogFilter("INFO", []string{"ERROR"}, true); err == nil {
		t.Fatal("expected mutually-exclusive filter rejection")
	}
	if _, ok := NewLogReaderHandler(contracts.Dependencies{}).(contracts.StreamingHandler); !ok {
		t.Fatal("streaming handler missing")
	}
}
