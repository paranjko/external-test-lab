package report

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBundledToolsAreContentAddressedAndRecoverMissingAssets(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	t.Setenv("LOCALAPPDATA", cache)
	t.Setenv("HOME", cache)
	dir, err := bundledToolDir()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, "allurerc.mjs")); err != nil {
		t.Fatal(err)
	}
	again, err := bundledToolDir()
	if err != nil || again != dir {
		t.Fatalf("second extraction: %s %v", again, err)
	}
	for _, name := range []string{"allurerc.mjs", "browser-check.mjs", "history-append.mjs", "package.json", "package-lock.json"} {
		want, _ := releaseAssets.ReadFile(name)
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || string(got) != string(want) {
			t.Fatalf("bundled asset %s: %v", name, err)
		}
	}
}
