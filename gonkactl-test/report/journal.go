// Package report converts authenticated runner journals into standard Allure
// result inputs. It never infers a successful step from a scenario status.
package report

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl-test/bindings"
)

type Identity struct {
	UUID          string
	HistoryID     string
	Feature       string
	Scenario      string
	FailureDomain string
}

type allureResult struct {
	UUID          string         `json:"uuid"`
	HistoryID     string         `json:"historyId"`
	Name          string         `json:"name"`
	FullName      string         `json:"fullName"`
	Status        string         `json:"status"`
	Stage         string         `json:"stage"`
	Steps         []allureStep   `json:"steps"`
	Labels        []allureLabel  `json:"labels"`
	StatusDetails *statusDetails `json:"statusDetails,omitempty"`
	Links         []any          `json:"links"`
	Start         int64          `json:"start"`
	Stop          int64          `json:"stop"`
}

type allureStep struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Stage  string `json:"stage"`
}
type allureLabel struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}
type statusDetails struct {
	Message string `json:"message"`
}

// ConvertScenario writes precisely the terminal scenario and reached-step
// outcomes from journalPath. A missing terminal event is an error, not PASS.
func ConvertScenario(journalPath, outputPath string, identity Identity) error {
	file, err := os.Open(journalPath)
	if err != nil {
		return err
	}
	defer file.Close()
	var events []bindings.JournalEvent
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var event bindings.JournalEvent
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return fmt.Errorf("decode journal: %w", err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	result := allureResult{UUID: identity.UUID, HistoryID: identity.HistoryID, Name: identity.Scenario, FullName: identity.Feature + ":" + identity.Scenario, Stage: "finished", Links: []any{}, Labels: []allureLabel{{Name: "epic", Value: "M0"}, {Name: "feature", Value: identity.Feature}, {Name: "story", Value: identity.Scenario}, {Name: "evidence_class", Value: "authentic-runner-journal"}}}
	for _, event := range events {
		if event.CaseID == nil || (*event.CaseID != identity.UUID && *event.CaseID != identity.Scenario) {
			continue
		}
		switch event.Kind {
		case "case_finished":
			result.Status = allureStatus(value(event.Outcome))
		case "assertion":
			name := "assertion"
			if event.AssertionID != nil {
				name = *event.AssertionID
			}
			result.Steps = append(result.Steps, allureStep{Name: name, Status: allureStatus(value(event.Outcome)), Stage: "finished"})
		}
	}
	if result.Status == "" {
		return fmt.Errorf("scenario %q has no terminal journal event", identity.Scenario)
	}
	if len(result.Steps) == 0 {
		return fmt.Errorf("scenario %q has no reached step evidence", identity.Scenario)
	}
	if result.Status == "passed" {
		for _, step := range result.Steps {
			if step.Status != "passed" {
				return fmt.Errorf("passed scenario %q includes non-passed reached step %q", identity.Scenario, step.Name)
			}
		}
	}
	if identity.FailureDomain != "" {
		result.Labels = append(result.Labels, allureLabel{Name: "failure_domain", Value: identity.FailureDomain})
		if result.Status != "passed" {
			result.StatusDetails = &statusDetails{Message: "failure domain: " + identity.FailureDomain + "; see authenticated runner journal"}
		}
	}
	sort.SliceStable(result.Steps, func(i, j int) bool { return i < j })
	encoded, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(outputPath, append(encoded, '\n'), 0o644)
}

func value(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}

func allureStatus(outcome string) string {
	switch strings.ToLower(outcome) {
	case "passed":
		return "passed"
	case "skipped", "pending", "undefined":
		return "skipped"
	case "failed":
		return "failed"
	default:
		return "broken"
	}
}
