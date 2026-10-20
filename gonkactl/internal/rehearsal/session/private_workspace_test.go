//go:build linux

package session

import (
	"os"
	"testing"
)

func privateWorkspace(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}
