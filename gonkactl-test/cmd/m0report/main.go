package main

import (
	"encoding/json"
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
	allureJournal, err := bindings.NewAllureEventJournal(filepath.Join(root, "pilot-allure-sdk-events.jsonl"))
	if err != nil {
		panic(err)
	}
	positiveJournal := filepath.Join(root, "pilot-events.jsonl")
	if status := bindings.RunGodogPilotWithOptions(bindings.PilotOptions{RunID: runID + "-positive", AttemptID: runID + "-positive-attempt", FeaturePath: filepath.Join("bindings", "features", "pilot.feature"), JournalPath: positiveJournal, EvidenceDir: filepath.Join(root, "positive-evidence"), AllureRuntime: allureJournal}); status != 0 {
		_ = allureJournal.Close()
		panic(fmt.Sprintf("positive pilot exited %d", status))
	}
	if err := allureJournal.Close(); err != nil {
		panic(err)
	}
	if err := convertSelected(positiveJournal, root, runID, "M0 Godog pilot", filepath.Join("bindings", "features", "pilot.selection.json")); err != nil {
		panic(err)
	}
	failureJournal := filepath.Join(root, "given-failure-events.jsonl")
	if status := bindings.RunGodogPilotWithOptions(bindings.PilotOptions{RunID: runID + "-negative", AttemptID: runID + "-negative-attempt", FeaturePath: filepath.Join("bindings", "features", "failure.feature"), JournalPath: failureJournal, EvidenceDir: filepath.Join(root, "negative-evidence")}); status == 0 {
		panic("negative pilot unexpectedly passed")
	}
	if err := convertSelected(failureJournal, root, runID, "M0 controlled negative pilot", filepath.Join("bindings", "features", "failure.selection.json")); err != nil {
		panic(err)
	}
}

func convertSelected(journal, outputDir, runID, feature, selectionPath string) error {
	contents, err := os.ReadFile(selectionPath)
	if err != nil {
		return fmt.Errorf("read declared selection: %w", err)
	}
	var selected []report.SelectedCase
	if err := json.Unmarshal(contents, &selected); err != nil {
		return fmt.Errorf("decode declared selection: %w", err)
	}
	conversion, err := report.ConvertSelectedJournal(journal, outputDir, runID, feature, selected)
	if err != nil {
		return err
	}
	if len(conversion.Gaps) != 0 {
		return fmt.Errorf("selected case reconciliation produced %d gap artifact(s)", len(conversion.Gaps))
	}
	return nil
}
