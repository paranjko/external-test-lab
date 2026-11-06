//go:build linux

package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestRehearsalInspectorCompositionRequiresExactImmutableConfig(t *testing.T) {
	root := t.TempDir()
	o := inspectorOptions{BinaryPath: filepath.Join(root, "inspector"), BinarySHA256: strings.Repeat("a", 64),
		Version: "synthetic", SourceCommit: strings.Repeat("b", 40), TempRoot: filepath.Join(root, "bounded-tmpfs"),
		MaxCopyBytes: 1024, MaxDumpBytes: 1024, MaxOutputFSBytes: 4096, TimeoutSeconds: 10, MaxLogBytes: 1024, ReserveBytes: 1024}
	raw, err := json.Marshal(o)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "inspector.json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	b := contract.RunBinding{Paths: map[string]string{"producer-binary": o.BinaryPath, "inspector-temp": o.TempRoot},
		InputDigests: map[string]string{"producer-binary": o.BinarySHA256, "inspector-config": contract.PayloadDigest(raw)}}
	reader, err := selectInspectorReader(path, b, nil)
	if err != nil || reader == nil {
		t.Fatalf("compose pinned reader: %v", err)
	}
	// Construction must not launch the producer or create the configured paths.
	if _, err := os.Stat(o.TempRoot); !os.IsNotExist(err) {
		t.Fatalf("composition mutated output: %v", err)
	}
	if _, err := selectInspectorReader("", b, nil); err == nil {
		t.Fatal("missing pinned config accepted")
	}
	if _, err := selectInspectorReader(path, b, reader); err == nil {
		t.Fatal("ambiguous reader accepted")
	}
	b.InputDigests["producer-binary"] = strings.Repeat("c", 64)
	if _, err := selectInspectorReader(path, b, nil); err == nil {
		t.Fatal("changed executable pin accepted")
	}
	b.InputDigests["producer-binary"] = o.BinarySHA256
	if err := os.WriteFile(path, append(raw, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := selectInspectorReader(path, b, nil); err == nil {
		t.Fatal("changed config bytes accepted")
	}
	delete(b.InputDigests, "inspector-config")
	if _, err := selectInspectorReader(path, b, nil); err == nil {
		t.Fatal("unpinned config accepted")
	}
}
