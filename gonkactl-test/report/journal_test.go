package report

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestConvertScenarioDoesNotInventUnreachedPass(t *testing.T) {
	directory := filepath.Join("..", "build", "gonkactl-test", "report-test")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(directory, "failure.jsonl")
	if err := os.WriteFile(journal, []byte("{\"kind\":\"assertion\",\"case_id\":\"attempt-failure\",\"assertion_id\":\"Given\",\"outcome\":\"failed\"}\n{\"kind\":\"case_finished\",\"case_id\":\"attempt-failure\",\"outcome\":\"failed\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(directory, "failure-result.json")
	if err := ConvertScenario(journal, output, Identity{UUID: "attempt-failure", HistoryID: "history-failure", Feature: "M0", Scenario: "failure", FailureDomain: "fixture"}); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(contents, &result); err != nil {
		t.Fatal(err)
	}
	if result["status"] != "failed" {
		t.Fatalf("status=%v", result["status"])
	}
	if result["statusDetails"].(map[string]any)["message"] != "failure domain: fixture; see authenticated runner journal" {
		t.Fatalf("details=%v", result["statusDetails"])
	}
	steps := result["steps"].([]any)
	if len(steps) != 1 || steps[0].(map[string]any)["status"] != "failed" {
		t.Fatalf("steps=%v", steps)
	}
}

func TestConvertScenarioRejectsMissingTerminalOutcome(t *testing.T) {
	directory := filepath.Join("..", "build", "gonkactl-test", "report-test")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(directory, "partial.jsonl")
	if err := os.WriteFile(journal, []byte("{\"kind\":\"assertion\",\"case_id\":\"attempt-partial\",\"assertion_id\":\"Given\",\"outcome\":\"passed\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ConvertScenario(journal, filepath.Join(directory, "partial.json"), Identity{UUID: "attempt-partial", HistoryID: "history-partial", Feature: "M0", Scenario: "partial"}); err == nil {
		t.Fatal("missing terminal event accepted")
	}
}
