package code

import (
	"bytes"
	"context"
	"os"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/eventlog"
)

func TestAcceptance_C03_Code(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer read.Close()
	oldStdin := os.Stdin
	os.Stdin = read
	defer func() { os.Stdin = oldStdin }()
	if _, err := write.WriteString("{\"timestamp\":\"2026-09-11T00:00:00Z\",\"run_id\":\"r\",\"seq\":\"1\",\"level\":\"INFO\",\"event\":\"healthy\",\"context\":{},\"error\":null}\n{\"timestamp\":\"2026-09-11T00:00:01Z\",\"run_id\":\"r\",\"seq\":\"2\",\"level\":\"ERROR\",\"event\":\"failed\",\"context\":{},\"error\":null}\n"); err != nil {
		t.Fatal(err)
	}
	write.Close()
	reader := eventlog.NewLogReaderHandler(contracts.Dependencies{})
	var output bytes.Buffer
	input := []byte(`{"path":"-","failed":true,"format":"compact"}`)
	if err := reader.Stream(context.Background(), input, &output); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); got != "2026-09-11T00:00:01Z ERROR failed\n" {
		t.Fatalf("failed filter output = %q", got)
	}
}
