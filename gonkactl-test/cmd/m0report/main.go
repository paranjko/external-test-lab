package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl-test/bindings"
	"github.com/paranjko/external-test-lab/gonkactl-test/report"
)

func main() {
	runID := os.Getenv("GONKACTL_TEST_RUN_ID")
	if runID == "" {
		runID = "m0-run-1"
	}
	root := filepath.Join("..", "build", "gonkactl-test", "report", "results", runID)
	root, err := filepath.Abs(root)
	if err != nil {
		panic(err)
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		panic(err)
	}
	positiveJournal := filepath.Join(root, "pilot-events.jsonl")
	if status := bindings.RunGodogPilotWithOptions(bindings.PilotOptions{RunID: runID + "-positive", AttemptID: runID + "-positive-attempt", FeaturePath: filepath.Join("bindings", "features", "pilot.feature"), JournalPath: positiveJournal, EvidenceDir: filepath.Join(root, "positive-evidence")}); status != 0 {
		panic(fmt.Sprintf("positive pilot exited %d", status))
	}
	if _, err := report.ConvertJournal(positiveJournal, root, runID, "M0 Godog pilot"); err != nil {
		panic(err)
	}
	failureJournal := filepath.Join(root, "given-failure-events.jsonl")
	if status := bindings.RunGodogPilotWithOptions(bindings.PilotOptions{RunID: runID + "-negative", AttemptID: runID + "-negative-attempt", FeaturePath: filepath.Join("bindings", "features", "failure.feature"), JournalPath: failureJournal, EvidenceDir: filepath.Join(root, "negative-evidence")}); status == 0 {
		panic("negative pilot unexpectedly passed")
	}
	if _, err := report.ConvertJournal(failureJournal, root, runID, "M0 controlled negative pilot"); err != nil {
		panic(err)
	}
}
