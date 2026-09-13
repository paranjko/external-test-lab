package report

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl-test/bindings"
)

type Identity struct{ UUID, HistoryID, CaseID, Feature, Scenario, FailureDomain string }

// SelectedCase is the declared execution obligation. It deliberately lives
// outside the journal so a missing runner event cannot silently remove a case
// from report conversion.
type SelectedCase struct {
	CaseID        string `json:"case_id"`
	Scenario      string `json:"scenario"`
	FailureDomain string `json:"failure_domain,omitempty"`
}

type JournalConversion struct {
	Results []string `json:"results"`
	Gaps    []string `json:"gaps"`
}
type allureResult struct {
	UUID          string             `json:"uuid"`
	HistoryID     string             `json:"historyId"`
	Name          string             `json:"name"`
	FullName      string             `json:"fullName"`
	Status        string             `json:"status"`
	Stage         string             `json:"stage"`
	Steps         []allureStep       `json:"steps"`
	Labels        []allureLabel      `json:"labels"`
	Attachments   []allureAttachment `json:"attachments"`
	StatusDetails *statusDetails     `json:"statusDetails,omitempty"`
	Links         []any              `json:"links"`
	Start         int64              `json:"start"`
	Stop          int64              `json:"stop"`
}
type allureStep struct {
	Name        string             `json:"name"`
	Status      string             `json:"status"`
	Stage       string             `json:"stage"`
	Attachments []allureAttachment `json:"attachments"`
	Start       int64              `json:"start"`
	Stop        int64              `json:"stop"`
}
type allureAttachment struct {
	Name   string `json:"name"`
	Source string `json:"source"`
	Type   string `json:"type"`
}
type allureLabel struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}
type statusDetails struct {
	Message string `json:"message"`
}

// ConvertJournal converts every event-backed case. Stable case IDs are used as
// names because the journal deliberately contains no unauthenticated display name.
func ConvertJournal(journalPath, outputDir, runID, feature string) ([]string, error) {
	events, err := readJournal(journalPath)
	if err != nil {
		return nil, err
	}
	cases := map[string]bool{}
	for _, e := range events {
		if e.CaseID != nil {
			cases[*e.CaseID] = true
		}
	}
	if len(cases) == 0 {
		return nil, fmt.Errorf("journal has no selected cases")
	}
	selected := make([]SelectedCase, 0, len(cases))
	for id := range cases {
		selected = append(selected, SelectedCase{CaseID: id, Scenario: id})
	}
	sort.Slice(selected, func(i, j int) bool { return selected[i].CaseID < selected[j].CaseID })
	conversion, err := ConvertSelectedJournal(journalPath, outputDir, runID, feature, selected)
	if err != nil {
		return nil, err
	}
	return conversion.Results, nil
}

// ConvertSelectedJournal reconciles declared selected obligations with actual
// journal evidence. Observed-but-undeclared case IDs fail closed; selected
// cases without a terminal event receive a visible durable gap rather than an
// invented result.
func ConvertSelectedJournal(journalPath, outputDir, runID, feature string, selected []SelectedCase) (JournalConversion, error) {
	events, err := readJournal(journalPath)
	if err != nil {
		return JournalConversion{}, err
	}
	if len(selected) == 0 {
		return JournalConversion{}, fmt.Errorf("declared selected cases are required")
	}
	declared := make(map[string]SelectedCase, len(selected))
	for _, item := range selected {
		if item.CaseID == "" {
			return JournalConversion{}, fmt.Errorf("selected case has empty case id")
		}
		if _, exists := declared[item.CaseID]; exists {
			return JournalConversion{}, fmt.Errorf("duplicate declared case id %q", item.CaseID)
		}
		if item.Scenario == "" {
			item.Scenario = item.CaseID
		}
		declared[item.CaseID] = item
	}
	observed := map[string]bool{}
	terminal := map[string]bool{}
	for _, event := range events {
		if event.CaseID == nil {
			continue
		}
		id := *event.CaseID
		if _, ok := declared[id]; !ok {
			return JournalConversion{}, fmt.Errorf("observed undeclared case id %q", id)
		}
		observed[id] = true
		if event.Kind == "case_finished" || event.Kind == "interrupted" {
			terminal[id] = true
		}
	}
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return JournalConversion{}, err
	}
	ids := make([]string, 0, len(declared))
	for id := range declared {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	conversion := JournalConversion{Results: []string{}, Gaps: []string{}}
	for _, id := range ids {
		item := declared[id]
		if !observed[id] || !terminal[id] {
			gap := filepath.Join(outputDir, id+"-gap.json")
			if err := writeSelectedCaseGap(gap, journalPath, item, !observed[id]); err != nil {
				return JournalConversion{}, err
			}
			conversion.Gaps = append(conversion.Gaps, gap)
			continue
		}
		out := filepath.Join(outputDir, id+"-result.json")
		if err := convertEvents(events, journalPath, out, Identity{UUID: runID + "-" + id, HistoryID: id, CaseID: id, Feature: feature, Scenario: item.Scenario, FailureDomain: item.FailureDomain}); err != nil {
			return JournalConversion{}, err
		}
		conversion.Results = append(conversion.Results, out)
	}
	return conversion, nil
}

func writeSelectedCaseGap(path, journalPath string, item SelectedCase, unseen bool) error {
	reason := "selected case has no terminal event evidence"
	if unseen {
		reason = "selected case has no journal event evidence"
	}
	payload := map[string]any{
		"case_id":       item.CaseID,
		"scenario":      item.Scenario,
		"outcome":       "gap",
		"reason":        reason,
		"journal":       filepath.Base(journalPath),
		"evidence_kind": "selected-case-reconciliation",
	}
	b, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, append(b, '\n'), 0o644)
}
func ConvertScenario(journalPath, outputPath string, identity Identity) error {
	events, err := readJournal(journalPath)
	if err != nil {
		return err
	}
	return convertEvents(events, journalPath, outputPath, identity)
}
func readJournal(path string) ([]bindings.JournalEvent, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var events []bindings.JournalEvent
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 65536), 4<<20)
	for s.Scan() {
		var e bindings.JournalEvent
		if err := json.Unmarshal(s.Bytes(), &e); err != nil {
			return nil, fmt.Errorf("decode journal: %w", err)
		}
		events = append(events, e)
	}
	return events, s.Err()
}

func convertEvents(events []bindings.JournalEvent, journalPath, outputPath string, id Identity) error {
	r := allureResult{UUID: id.UUID, HistoryID: id.HistoryID, Name: id.Scenario, FullName: id.Feature + ":" + id.Scenario, Stage: "finished", Links: []any{}, Steps: []allureStep{}, Attachments: []allureAttachment{}, Labels: []allureLabel{{"epic", "M0"}, {"feature", id.Feature}, {"story", id.Scenario}, {"evidence_class", "authentic-runner-journal"}}}
	indexes := map[string]int{}
	started, terminal := false, false
	caseID := id.CaseID
	if caseID == "" {
		caseID = id.Scenario
	}
	for _, e := range events {
		if e.CaseID == nil || (*e.CaseID != id.UUID && *e.CaseID != caseID) {
			continue
		}
		switch e.Kind {
		case "case_started":
			if started {
				return fmt.Errorf("scenario %q has duplicate start", id.Scenario)
			}
			started = true
			startTime, err := eventTimeMS(e, false)
			if err != nil {
				return err
			}
			r.Start = startTime
		case "step_started":
			if !started || e.StepID == nil {
				return fmt.Errorf("scenario %q has invalid step start", id.Scenario)
			}
			indexes[*e.StepID] = len(r.Steps)
			stepStart, err := eventTimeMS(e, false)
			if err != nil {
				return err
			}
			r.Steps = append(r.Steps, allureStep{Name: *e.StepID, Stage: "finished", Start: stepStart, Attachments: []allureAttachment{}})
		case "assertion":
			if e.StepID == nil {
				return fmt.Errorf("assertion has no step")
			}
			i, ok := indexes[*e.StepID]
			if !ok {
				return fmt.Errorf("assertion precedes step")
			}
			r.Steps[i].Status = allureStatus(value(e.Outcome))
			stepStop, err := eventTimeMS(e, true)
			if err != nil {
				return err
			}
			r.Steps[i].Stop = stepStop
			if r.Steps[i].Stop <= r.Steps[i].Start {
				return fmt.Errorf("step %q has no positive observed duration", r.Steps[i].Name)
			}
		case "attachment":
			if e.StepID == nil || len(e.AttachmentRefs) == 0 {
				return fmt.Errorf("malformed attachment")
			}
			i, stepKnown := indexes[*e.StepID]
			for _, ref := range e.AttachmentRefs {
				a, err := copyAttachment(journalPath, outputPath, ref)
				if err != nil {
					return err
				}
				if stepKnown {
					r.Steps[i].Attachments = append(r.Steps[i].Attachments, a)
				} else {
					// The v1 journal's evidence assertion ID is deliberately
					// distinct from the Gherkin step ID. Preserve it at case scope.
					r.Attachments = append(r.Attachments, a)
				}
			}
		case "case_finished":
			r.Status = allureStatus(value(e.Outcome))
			stopTime, err := eventTimeMS(e, true)
			if err != nil {
				return err
			}
			r.Stop = stopTime
			terminal = true
			if e.Reason != nil {
				r.StatusDetails = &statusDetails{Message: *e.Reason}
			}
		}
	}
	if !started || !terminal {
		return fmt.Errorf("scenario %q has incomplete start/terminal evidence", id.Scenario)
	}
	if r.Stop <= r.Start {
		return fmt.Errorf("scenario %q has no positive observed duration", id.Scenario)
	}
	if len(r.Steps) == 0 {
		return fmt.Errorf("scenario %q has no reached step evidence", id.Scenario)
	}
	for _, s := range r.Steps {
		if s.Status == "" {
			return fmt.Errorf("step %q has no assertion", s.Name)
		}
		if r.Status == "passed" && s.Status != "passed" {
			return fmt.Errorf("passed scenario includes non-passed step")
		}
	}
	if id.FailureDomain != "" {
		r.Labels = append(r.Labels, allureLabel{"failure_domain", id.FailureDomain})
		if r.Status != "passed" && r.StatusDetails == nil {
			r.StatusDetails = &statusDetails{Message: "failure domain: " + id.FailureDomain + "; see authenticated runner journal"}
		}
	} else if r.Status != "passed" {
		// The journal proves that the runner assertion path, rather than the
		// renderer, produced this failure. Do not infer a product subsystem.
		r.Labels = append(r.Labels, allureLabel{"failure_domain", "runner-assertion"})
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(outputPath, append(b, '\n'), 0644)
}
func copyAttachment(journalPath, outputPath, ref string) (allureAttachment, error) {
	clean := filepath.Clean(filepath.FromSlash(ref))
	if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(os.PathSeparator)) {
		return allureAttachment{}, fmt.Errorf("attachment escapes journal root: %q", ref)
	}
	src := filepath.Join(filepath.Dir(journalPath), clean)
	in, err := os.Open(src)
	if err != nil {
		return allureAttachment{}, err
	}
	defer in.Close()
	name := filepath.Base(clean)
	source := strings.TrimSuffix(filepath.Base(outputPath), "-result.json") + "-" + name
	out, err := os.OpenFile(filepath.Join(filepath.Dir(outputPath), source), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return allureAttachment{}, err
	}
	_, cp := io.Copy(out, in)
	syncErr := out.Sync()
	closeErr := out.Close()
	if cp != nil {
		return allureAttachment{}, cp
	}
	if syncErr != nil {
		return allureAttachment{}, syncErr
	}
	if closeErr != nil {
		return allureAttachment{}, closeErr
	}
	return allureAttachment{Name: name, Source: source, Type: "application/json"}, nil
}
func atomicWrite(path string, b []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".promote-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	if e := f.Close(); err == nil {
		err = e
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
func value(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}

func eventTimeMS(event bindings.JournalEvent, roundUp bool) (int64, error) {
	observed, err := time.Parse(time.RFC3339Nano, event.Timestamp)
	if err != nil {
		return 0, fmt.Errorf("event %q has invalid observed timestamp: %w", event.EventID, err)
	}
	nanos := observed.UnixNano()
	if roundUp && nanos%int64(time.Millisecond) != 0 {
		return nanos/int64(time.Millisecond) + 1, nil
	}
	return nanos / int64(time.Millisecond), nil
}
func allureStatus(v string) string {
	switch strings.ToLower(v) {
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
