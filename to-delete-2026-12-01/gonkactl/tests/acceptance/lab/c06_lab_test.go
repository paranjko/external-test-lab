package lab

import (
	"os"
	"testing"
)

// TestAcceptance_C06_Lab is deliberately not a synthetic substitute for the
// disposable-runtime fault campaign. The gate wrapper refuses to run it until
// an authorized docker_lab environment manifest is supplied.
func TestAcceptance_C06_Lab(t *testing.T) {
	if os.Getenv("GONKACTL_TEST_ENV") == "" {
		t.Skip("requires separately authorized disposable runtime fault harness")
	}
	t.Fatal("C06.lab requires the separately authorized disposable runtime fault harness")
}
