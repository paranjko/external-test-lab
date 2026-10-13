package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"
)

func TestPerfettoArtifactRoutes(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"manifest", "analysis", "view", "private"} {
		if err := os.WriteFile(filepath.Join(dir, name+".json"), []byte(name), 0600); err != nil {
			t.Fatal(err)
		}
	}
	const origin = "http://127.0.0.1:9999"
	h := perfettoHandler(origin, "sample", dir, PFAnalysis{}, fstest.MapFS{})
	for _, name := range []string{"manifest", "analysis", "view", "private", "view.json", "%2e%2e/private", "view%2f..%2fprivate", "%2fprivate", "..%5cprivate"} {
		t.Run(name, func(t *testing.T) {
			r := httptest.NewRequest("GET", origin+"/api/session/sample/"+name, nil)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if name == "manifest" || name == "analysis" || name == "view" {
				if w.Code != 200 || w.Body.String() != name {
					t.Fatalf("wrong artifact: %d %q", w.Code, w.Body.String())
				}
			} else if w.Code != 404 {
				t.Fatalf("unexpected route accepted: %d %q", w.Code, w.Body.String())
			}
		})
	}
}
