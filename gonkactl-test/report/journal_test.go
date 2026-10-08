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
	if err := os.WriteFile(journal, []byte("{\"kind\":\"case_started\",\"case_id\":\"attempt-failure\",\"elapsed_ms\":0,\"timestamp\":\"2026-01-01T00:00:00.000100000Z\"}\n{\"kind\":\"step_started\",\"case_id\":\"attempt-failure\",\"step_id\":\"Given\",\"elapsed_ms\":0,\"timestamp\":\"2026-01-01T00:00:00.000200000Z\"}\n{\"kind\":\"assertion\",\"case_id\":\"attempt-failure\",\"step_id\":\"Given\",\"assertion_id\":\"Given\",\"outcome\":\"failed\",\"elapsed_ms\":0,\"timestamp\":\"2026-01-01T00:00:00.000300000Z\"}\n{\"kind\":\"case_finished\",\"case_id\":\"attempt-failure\",\"outcome\":\"failed\",\"elapsed_ms\":0,\"timestamp\":\"2026-01-01T00:00:00.000400000Z\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(directory, "failure-result.json")
	if err := ConvertScenario(journal, output, Identity{UUID: "attempt-failure", HistoryID: "history-failure", Feature: "Qualification", Scenario: "failure", FailureDomain: "fixture"}); err != nil {
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
	if result["start"].(float64) == 0 || result["stop"].(float64) <= result["start"].(float64) {
		t.Fatalf("zero elapsed fields became placeholder timing: start=%v stop=%v", result["start"], result["stop"])
	}
	step := steps[0].(map[string]any)
	if step["stop"].(float64)-step["start"].(float64) != 1 {
		t.Fatalf("sub-millisecond observed step duration was not preserved: %v", step)
	}
}

func TestConvertScenarioRejectsMissingTerminalOutcome(t *testing.T) {
	directory := filepath.Join("..", "build", "gonkactl-test", "report-test")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(directory, "partial.jsonl")
	if err := os.WriteFile(journal, []byte("{\"kind\":\"case_started\",\"case_id\":\"attempt-partial\",\"timestamp\":\"2026-01-01T00:00:00.000100000Z\"}\n{\"kind\":\"step_started\",\"case_id\":\"attempt-partial\",\"step_id\":\"Given\",\"timestamp\":\"2026-01-01T00:00:00.000200000Z\"}\n{\"kind\":\"assertion\",\"case_id\":\"attempt-partial\",\"step_id\":\"Given\",\"assertion_id\":\"Given\",\"outcome\":\"passed\",\"timestamp\":\"2026-01-01T00:00:00.000300000Z\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ConvertScenario(journal, filepath.Join(directory, "partial.json"), Identity{UUID: "attempt-partial", HistoryID: "history-partial", Feature: "Qualification", Scenario: "partial"}); err == nil {
		t.Fatal("missing terminal event accepted")
	}
}

func TestConvertSelectedJournalWritesVisibleGapForSelectedUnseenCase(t *testing.T) {
	directory := filepath.Join("..", "build", "gonkactl-test", "report-test", "selection-gap")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(directory, "events.jsonl")
	contents := "{\"kind\":\"case_started\",\"case_id\":\"observed\",\"timestamp\":\"2026-01-01T00:00:00.000100000Z\"}\n" +
		"{\"kind\":\"step_started\",\"case_id\":\"observed\",\"step_id\":\"Given\",\"timestamp\":\"2026-01-01T00:00:00.000200000Z\"}\n" +
		"{\"kind\":\"assertion\",\"case_id\":\"observed\",\"step_id\":\"Given\",\"outcome\":\"passed\",\"timestamp\":\"2026-01-01T00:00:00.000300000Z\"}\n" +
		"{\"kind\":\"case_finished\",\"case_id\":\"observed\",\"outcome\":\"passed\",\"timestamp\":\"2026-01-01T00:00:00.000400000Z\"}\n"
	if err := os.WriteFile(journal, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
	conversion, err := ConvertSelectedJournal(journal, directory, "run", "Qualification", []SelectedCase{{CaseID: "observed", Scenario: "Observed"}, {CaseID: "unseen", Scenario: "Unseen"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(conversion.Results) != 1 || len(conversion.Gaps) != 1 {
		t.Fatalf("conversion=%+v", conversion)
	}
	gap, err := os.ReadFile(conversion.Gaps[0])
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(gap, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["case_id"] != "unseen" || payload["outcome"] != "gap" {
		t.Fatalf("gap=%v", payload)
	}
}

func TestConvertSelectedJournalRejectsObservedUndeclaredCase(t *testing.T) {
	directory := filepath.Join("..", "build", "gonkactl-test", "report-test", "selection-unknown")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(directory, "events.jsonl")
	if err := os.WriteFile(journal, []byte("{\"kind\":\"case_started\",\"case_id\":\"undeclared\",\"timestamp\":\"2026-01-01T00:00:00Z\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ConvertSelectedJournal(journal, directory, "run", "Qualification", []SelectedCase{{CaseID: "declared", Scenario: "Declared"}}); err == nil {
		t.Fatal("observed undeclared case accepted")
	}
}

func TestConvertScenarioSeparatesCollidingAttachmentsAndReconversion(t *testing.T) {
	directory := t.TempDir()
	for path, contents := range map[string]string{
		filepath.Join(directory, "first", "observation.json"):  "{\"source\":\"first\"}\n",
		filepath.Join(directory, "second", "observation.json"): "{\"source\":\"second\"}\n",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	journal := filepath.Join(directory, "events.jsonl")
	events := "{\"kind\":\"case_started\",\"case_id\":\"attachment-case\",\"timestamp\":\"2026-01-01T00:00:00.000100000Z\"}\n" +
		"{\"kind\":\"step_started\",\"case_id\":\"attachment-case\",\"step_id\":\"Given\",\"timestamp\":\"2026-01-01T00:00:00.000200000Z\"}\n" +
		"{\"kind\":\"attachment\",\"case_id\":\"attachment-case\",\"step_id\":\"Given\",\"attachment_refs\":[\"first/observation.json\",\"second/observation.json\"]}\n" +
		"{\"kind\":\"assertion\",\"case_id\":\"attachment-case\",\"step_id\":\"Given\",\"outcome\":\"passed\",\"timestamp\":\"2026-01-01T00:00:00.000300000Z\"}\n" +
		"{\"kind\":\"case_finished\",\"case_id\":\"attachment-case\",\"outcome\":\"passed\",\"timestamp\":\"2026-01-01T00:00:00.000400000Z\"}\n"
	if err := os.WriteFile(journal, []byte(events), 0o644); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(directory, "attachment-result.json")
	identity := Identity{UUID: "attachment-case", HistoryID: "history-attachment", Feature: "Qualification", Scenario: "attachment-case"}
	if err := ConvertScenario(journal, output, identity); err != nil {
		t.Fatal(err)
	}
	if err := ConvertScenario(journal, output, identity); err != nil {
		t.Fatalf("deterministic reconversion failed: %v", err)
	}
	contents, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(contents, &result); err != nil {
		t.Fatal(err)
	}
	attachments := result["steps"].([]any)[0].(map[string]any)["attachments"].([]any)
	if len(attachments) != 2 {
		t.Fatalf("attachments=%v", attachments)
	}
	first := attachments[0].(map[string]any)["source"].(string)
	second := attachments[1].(map[string]any)["source"].(string)
	if first == second {
		t.Fatalf("colliding attachment names reused source: %q", first)
	}
	for source, want := range map[string]string{first: "{\"source\":\"first\"}\n", second: "{\"source\":\"second\"}\n"} {
		got, err := os.ReadFile(filepath.Join(directory, source))
		if err != nil || string(got) != want {
			t.Fatalf("attachment %s got=%q err=%v", source, got, err)
		}
	}
}
