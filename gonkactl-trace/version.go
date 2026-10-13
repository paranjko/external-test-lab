package main

import "fmt"

// Release builds set these fields with -ldflags -X.
var (
	version   = "dev"
	commit    = "unknown"
	buildDate = "unknown"
)

func versionString() string {
	return fmt.Sprintf("gonkactl-trace %s (commit %s, built %s)", version, commit, buildDate)
}
