package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl-test/bindings"
	"github.com/paranjko/external-test-lab/gonkactl-test/contracts"
	"github.com/paranjko/external-test-lab/gonkactl-test/report"
)

func main() {
	runID := os.Getenv("GONKACTL_TEST_RUN_ID")
	if runID == "" {
		runID = "m0-run-1"
	}
	root := filepath.Join("..", "build", "gonkactl-test", "report", "results", runID)
	if err := os.MkdirAll(root, 0o755); err != nil {
		panic(err)
	}
	identity, err := (contracts.SemanticIdentityV1{ScenarioID: "m0-godog-pilot", ContractRevision: "v1", VariantID: "v5-mock", EnvironmentClass: "lab-mock", ComputeMode: "mock", ComparisonSlot: "candidate", HistoryPolicyRevision: "v1"}).HistoryID()
	if err != nil {
		panic(err)
	}
	positiveJournal := filepath.Join(root, "pilot-events.jsonl")
	if status := bindings.RunGodogPilot(filepath.Join("bindings", "features", "pilot.feature"), positiveJournal); status != 0 {
		panic(fmt.Sprintf("positive pilot exited %d", status))
	}
	if err := report.ConvertScenario(positiveJournal, filepath.Join(root, "pilot-result.json"), report.Identity{UUID: runID + "-pilot-attempt", HistoryID: identity, Feature: "M0 Godog pilot", Scenario: "Проверки не выводятся из renderer"}); err != nil {
		panic(err)
	}
	failureJournal := filepath.Join(root, "given-failure-events.jsonl")
	if status := bindings.RunGodogPilot(filepath.Join("bindings", "features", "failure.feature"), failureJournal); status == 0 {
		panic("negative pilot unexpectedly passed")
	}
	if err := report.ConvertScenario(failureJournal, filepath.Join(root, "given-failure-result.json"), report.Identity{UUID: runID + "-given-failure-attempt", HistoryID: identity + "-negative", Feature: "M0 Godog pilot", Scenario: "Given прекращает assertions", FailureDomain: "fixture"}); err != nil {
		panic(err)
	}
}
