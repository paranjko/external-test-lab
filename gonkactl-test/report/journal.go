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

type Identity struct{ UUID, HistoryID, Feature, Scenario, FailureDomain string }
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
	ids := make([]string, 0, len(cases))
	for id := range cases {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return nil, err
	}
	outputs := make([]string, 0, len(ids))
	for _, id := range ids {
		out := filepath.Join(outputDir, id+"-result.json")
		if err := convertEvents(events, journalPath, out, Identity{UUID: runID + "-" + id, HistoryID: id, Feature: feature, Scenario: id}); err != nil {
			return nil, err
		}
		outputs = append(outputs, out)
	}
	return outputs, nil
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
	for _, e := range events {
		if e.CaseID == nil || (*e.CaseID != id.UUID && *e.CaseID != id.Scenario) {
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
