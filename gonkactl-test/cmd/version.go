package main

// Release builds inject these values with -ldflags -X.
var (
	version   = "dev"
	commit    = "unknown"
	buildTime = "unknown"
)
