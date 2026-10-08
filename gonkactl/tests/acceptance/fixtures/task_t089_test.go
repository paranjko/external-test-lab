package fixtures

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTask_T089(t *testing.T) {
	path := filepath.Join("..", "..", "..", "testdata", "acceptance", "fixture-manifest.json")
	if err := Verify(path); err != nil {
		t.Fatal(err)
	}
	manifest, err := Load(path)
	if err != nil || manifest.SchemaVersion != 1 || len(manifest.Fixtures) < 5 {
		t.Fatalf("manifest=%#v err=%v", manifest, err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(path), "legacy-producer.tar.gz")); err != nil {
		t.Fatal(err)
	}
}
