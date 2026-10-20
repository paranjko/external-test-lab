package executil

import (
	"context"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func TestInterpreterAndScriptExecutablesAreRejected(t *testing.T) {
	for _, executable := range []string{"sh", "bash", "/usr/bin/python3", "python", "/tmp/operation.sh", "/tmp/operation.py"} {
		_, err := NewRunner().Run(context.Background(), contracts.ProcessSpec{Executable: executable})
		if err == nil {
			t.Fatalf("interpreter or script accepted: %s", executable)
		}
	}
}
