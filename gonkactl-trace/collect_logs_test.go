package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHistoricalDockerLogsDoNotTailAwayOldWindow(t *testing.T) {
	dir := t.TempDir()
	// Simulate Docker: tail selects the newest lines before the historic until
	// filter, so a noisy container returns no old lines when both are supplied.
	ssh := "#!/bin/sh\nfor arg do command=$arg; done\ncase \"$command\" in\n*inspect*) echo '{}' ;;\n*'--since'*'--tail'*|*'--tail'*'--since'*) exit 0 ;;\n*) echo '2026-09-09T18:58:44Z retained API log' ;;\nesac\n"
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(ssh), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	x := collector{dir: dir, d: Dataset{Config: Config{TimeoutSeconds: 2}, Start: time.Date(2026, 9, 9, 18, 58, 0, 0, time.UTC), End: time.Date(2026, 9, 9, 18, 59, 0, 0, time.UTC)}}
	x.logs(Node{ID: "node1", SSH: "test-host"}, 0, LogSource{Kind: "docker", Path: "api", Component: "api"})
	if len(x.d.Receipts) != 1 || x.d.Receipts[0].Error != "" {
		t.Fatalf("lost historic logs: %+v", x.d.Receipts)
	}
	b, err := os.ReadFile(x.d.Receipts[0].Path)
	if err != nil || !strings.Contains(string(b), "retained API log") {
		t.Fatalf("%s %v", b, err)
	}
}
