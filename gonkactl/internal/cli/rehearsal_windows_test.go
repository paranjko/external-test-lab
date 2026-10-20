//go:build windows

package cli

import (
	"strings"
	"testing"
)

func TestWindowsKeepsOrdinaryCommandsAndRefusesRecovery(t *testing.T) {
	root := NewRoot()
	for _, name := range []string{"version", "bootstrap", "recover"} {
		if command, _, err := root.Find([]string{name}); err != nil || command == nil {
			t.Fatalf("ordinary command %q unavailable: %v", name, err)
		}
	}
	root.SetArgs([]string{"recover", "epoch-length-live-update", "inspect"})
	err := root.Execute()
	if err == nil || !strings.Contains(err.Error(), "unavailable on Windows") {
		t.Fatalf("expected explicit unsupported recovery refusal, got %v", err)
	}
}
