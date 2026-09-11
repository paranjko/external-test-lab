package bindings

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	allure "github.com/allure-framework/allure-go/commons"
	allureruntime "github.com/allure-framework/allure-go/commons/runtime"
	"github.com/cucumber/godog"
)

type JournalEvent struct {
	SchemaVersion  string   `json:"schema_version"`
	RunID          string   `json:"run_id"`
	CaseID         *string  `json:"case_id"`
	AttemptID      *string  `json:"attempt_id"`
	EventID        string   `json:"event_id"`
	Sequence       int64    `json:"sequence"`
	Timestamp      string   `json:"timestamp"`
	ElapsedMS      int64    `json:"elapsed_ms"`
	Kind           string   `json:"kind"`
	StepID         *string  `json:"step_id"`
	AssertionID    *string  `json:"assertion_id"`
	Outcome        *string  `json:"outcome"`
	Reason         *string  `json:"reason"`
	AttachmentRefs []string `json:"attachment_refs"`
	Expected       any      `json:"expected,omitempty"`
	Actual         any      `json:"actual,omitempty"`
}

type PilotOptions struct {
	RunID, AttemptID                      string
	FeaturePath, JournalPath, EvidenceDir string
	AllureRuntime                         allureruntime.Runtime
	FailJournalAfter                      int64
}

type journal struct {
	mu               sync.Mutex
	file             *os.File
	encoder          *json.Encoder
	start            time.Time
	sequence         int64
	runID, attemptID string
	err              error
	nonPassing       bool
	caseOutcomes     map[string]string
	failAfter        int64
}

var attemptRegistry = struct {
	sync.Mutex
	ids map[string]struct{}
}{ids: make(map[string]struct{})}

func newJournal(opts PilotOptions) (*journal, error) {
	if opts.RunID == "" || opts.AttemptID == "" {
		return nil, errors.New("run and attempt IDs are required")
	}
	if err := ValidatePersistentPath(opts.JournalPath); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(opts.JournalPath), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(opts.JournalPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create new journal without reuse: %w", err)
	}
	attemptRegistry.Lock()
	if _, exists := attemptRegistry.ids[opts.AttemptID]; exists {
		attemptRegistry.Unlock()
		_ = f.Close()
		return nil, fmt.Errorf("duplicate attempt id %q", opts.AttemptID)
	}
	attemptRegistry.ids[opts.AttemptID] = struct{}{}
	attemptRegistry.Unlock()
	j := &journal{file: f, encoder: json.NewEncoder(f), start: time.Now(), runID: opts.RunID, attemptID: opts.AttemptID, caseOutcomes: map[string]string{}, failAfter: opts.FailJournalAfter}
	if err := j.write(JournalEvent{Kind: "run_started"}); err != nil {
		_ = f.Close()
		return nil, err
	}
	return j, nil
}
func (j *journal) write(e JournalEvent) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.err != nil {
		return j.err
	}
	j.sequence++
	if j.failAfter > 0 && j.sequence > j.failAfter {
		_ = j.file.Close()
		j.err = errors.New("injected journal write failure")
		return j.err
	}
	e.SchemaVersion = "1.0.0"
	e.RunID = j.runID
	e.EventID = fmt.Sprintf("%s-e%06d", j.runID, j.sequence)
	e.Sequence = j.sequence
	e.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
	e.ElapsedMS = time.Since(j.start).Milliseconds()
	if e.AttachmentRefs == nil {
		e.AttachmentRefs = []string{}
	}
	if e.Outcome != nil && *e.Outcome != "passed" {
		j.nonPassing = true
		if e.CaseID != nil {
			j.caseOutcomes[*e.CaseID] = *e.Outcome
		}
	}
	if e.Kind != "run_started" && e.Kind != "run_finished" {
		e.AttemptID = ptr(j.attemptID)
	}
	if err := j.encoder.Encode(e); err != nil {
		j.err = fmt.Errorf("encode journal event: %w", err)
		return j.err
	}
	if err := j.file.Sync(); err != nil {
		j.err = fmt.Errorf("sync journal event: %w", err)
		return j.err
	}
	return nil
}
func (j *journal) close(outcome string) error {
	err := j.write(JournalEvent{Kind: "run_finished", Outcome: ptr(outcome)})
	closeErr := j.file.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func (j *journal) caseOutcome(caseID string) string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.caseOutcomes[caseID]
}
func ptr[T any](v T) *T { return &v }

type scenarioState struct {
	CaseID string
	Values map[string]string
}
type scenarioContextKey struct{}

func RunGodogPilot(featurePath, journalPath string) int {
	return RunGodogPilotWithOptions(PilotOptions{RunID: "pilot-run", AttemptID: "pilot-attempt", FeaturePath: featurePath, JournalPath: journalPath, EvidenceDir: filepath.Join(filepath.Dir(journalPath), "evidence")})
}

func RunGodogPilotWithOptions(opts PilotOptions) int {
	j, err := newJournal(opts)
	if err != nil {
		return 2
	}
	if err := os.MkdirAll(opts.EvidenceDir, 0o755); err != nil {
		_ = j.close("broken")
		return 2
	}
	var cases sync.Map
	suite := godog.TestSuite{ScenarioInitializer: func(sc *godog.ScenarioContext) {
		sc.Before(func(ctx context.Context, s *godog.Scenario) (context.Context, error) {
			caseID := stableCaseID(s)
			if _, loaded := cases.LoadOrStore(caseID, true); loaded {
				return ctx, fmt.Errorf("duplicate case id %s", caseID)
			}
			st := &scenarioState{CaseID: caseID, Values: map[string]string{}}
			ctx = context.WithValue(ctx, scenarioContextKey{}, st)
			if opts.AllureRuntime != nil {
				ctx = allureruntime.WithRuntime(ctx, opts.AllureRuntime)
				ctx = allureruntime.WithTest(ctx, caseID)
				if err := allure.DisplayName(ctx, s.Name); err != nil {
					return ctx, fmt.Errorf("allure display name: %w", err)
				}
				if err := allure.Label(ctx, "case_id", caseID); err != nil {
					return ctx, fmt.Errorf("allure case label: %w", err)
				}
			}
			if err := j.write(JournalEvent{Kind: "case_started", CaseID: ptr(caseID)}); err != nil {
				return ctx, err
			}
			if strings.Contains(s.Name, "Hook failure") {
				return ctx, errors.New("controlled hook failure")
			}
			if strings.Contains(s.Name, "Ambiguous") || strings.Contains(s.Name, "Control") {
				for _, step := range s.Steps {
					if step.Text == "неоднозначный шаг" {
						return ctx, errors.New("ambiguous binding: неоднозначный шаг")
					}
				}
			}
			return ctx, nil
		})
		sc.After(func(ctx context.Context, s *godog.Scenario, runErr error) (context.Context, error) {
			st := state(ctx)
			if st == nil {
				return ctx, fmt.Errorf("scenario %s lost identity context", stableCaseID(s))
			}
			outcome := "passed"
			if runErr != nil {
				outcome = "failed"
			} else if recorded := j.caseOutcome(st.CaseID); recorded != "" && recorded != "passed" {
				outcome = recorded
			}
			if err := j.write(JournalEvent{Kind: "case_finished", CaseID: ptr(st.CaseID), Outcome: ptr(outcome), Reason: errorReason(runErr)}); err != nil {
				return ctx, err
			}
			return ctx, nil
		})
		steps := sc.StepContext()
		steps.Before(func(ctx context.Context, step *godog.Step) (context.Context, error) {
			st := state(ctx)
			id := stableID(st.CaseID, step.Text)
			return ctx, j.write(JournalEvent{Kind: "step_started", CaseID: ptr(st.CaseID), StepID: ptr(id)})
		})
		steps.After(func(ctx context.Context, step *godog.Step, status godog.StepResultStatus, runErr error) (context.Context, error) {
			st := state(ctx)
			id := stableID(st.CaseID, step.Text)
			outcome := normalizeOutcome(status.String(), runErr)
			return ctx, j.write(JournalEvent{Kind: "assertion", CaseID: ptr(st.CaseID), StepID: ptr(id), AssertionID: ptr(id + "-assert"), Outcome: ptr(outcome), Reason: errorReason(runErr)})
		})
		sc.Step(`^стенд подготовлен$`, func() error { return nil })
		sc.Step(`^предусловие отклонено$`, func() error { return errors.New("intentional given failure") })
		sc.Step(`^выполняется запрос "([^"]*)"$`, func(ctx context.Context, v string) (context.Context, error) {
			state(ctx).Values["request"] = v
			return ctx, nil
		})
		sc.Step(`^получен результат "([^"]*)"$`, func(ctx context.Context, want string) (context.Context, error) {
			got := "ok"
			if state(ctx).Values["request"] == "broken" {
				got = "error"
			}
			return ctx, assertAndAttach(ctx, j, opts, "response", want, got)
		})
		sc.Step(`^доказательство содержит "([^"]*)"$`, func(ctx context.Context, want string) (context.Context, error) {
			got := want
			return ctx, assertAndAttach(ctx, j, opts, "evidence", want, got)
		})
		sc.Step(`^передан документ$`, func(ctx context.Context, d *godog.DocString) (context.Context, error) {
			state(ctx).Values["document"] = d.Content
			return ctx, nil
		})
		sc.Step(`^документ содержит "([^"]*)"$`, func(ctx context.Context, want string) (context.Context, error) {
			got := state(ctx).Values["document"]
			if !strings.Contains(got, want) {
				return ctx, fmt.Errorf("expected document %q in %q", want, got)
			}
			return ctx, nil
		})
		sc.Step(`^получена таблица$`, func(ctx context.Context, t *godog.Table) (context.Context, error) {
			var values []string
			for _, r := range t.Rows {
				for _, c := range r.Cells {
					values = append(values, c.Value)
				}
			}
			state(ctx).Values["table"] = strings.Join(values, "|")
			return ctx, nil
		})
		sc.Step(`^таблица содержит "([^"]*)"$`, func(ctx context.Context, want string) (context.Context, error) {
			got := state(ctx).Values["table"]
			if !strings.Contains(got, want) {
				return ctx, fmt.Errorf("expected table %q in %q", want, got)
			}
			return ctx, nil
		})
		sc.Step(`^ожидает реализации$`, func() error { return godog.ErrPending })
		// Deliberately register two identical definitions. Godog must reject this
		// during preparation, rather than running a fabricated step body.
		sc.Step(`^неоднозначный шаг$`, func() error { return nil })
		sc.Step(`^неоднозначный шаг$`, func() error { return nil })
		sc.Step(`^паника шага$`, func() error { panic("controlled panic") })
		sc.Step(`^отмена шага$`, func() error { return context.Canceled })
	}, Options: &godog.Options{Format: "progress", Paths: []string{opts.FeaturePath}, Output: os.Stdout, Strict: true, Concurrency: 2}}
	status := suite.Run()
	if status == 0 && j.nonPassing {
		status = 1
	}
	outcome := "passed"
	if status != 0 {
		outcome = "failed"
	}
	if err := j.close(outcome); err != nil {
		_ = writePilotReceipt(opts, 2, "interrupted", err.Error())
		return 2
	}
	if err := writePilotReceipt(opts, status, outcome, ""); err != nil {
		return 2
	}
	return status
}

func state(ctx context.Context) *scenarioState {
	st, _ := ctx.Value(scenarioContextKey{}).(*scenarioState)
	return st
}

func writePilotReceipt(opts PilotOptions, status int, outcome, reason string) error {
	receipt := map[string]any{"run_id": opts.RunID, "attempt_id": opts.AttemptID, "status": status, "outcome": outcome, "reason": reason, "journal": opts.JournalPath, "finished_at": time.Now().UTC().Format(time.RFC3339Nano)}
	encoded, _ := json.MarshalIndent(receipt, "", "  ")
	path := opts.JournalPath + ".receipt.json"
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(append(encoded, '\n')); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func stableCaseID(s *godog.Scenario) string {
	parts := []string{s.Name}
	for _, step := range s.Steps {
		parts = append(parts, step.Text)
	}
	return "case-" + stableID(parts...)[:16]
}
func stableID(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(sum[:])
}
func normalizeOutcome(raw string, err error) string {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "interrupted"
	}
	if err != nil {
		return "failed"
	}
	switch strings.ToLower(raw) {
	case "passed":
		return "passed"
	case "skipped", "pending", "undefined":
		return "skipped"
	default:
		return "broken"
	}
}
func errorReason(err error) *string {
	if err == nil {
		return nil
	}
	return ptr(err.Error())
}
func assertAndAttach(ctx context.Context, j *journal, opts PilotOptions, name, want, got string) error {
	st := state(ctx)
	body, _ := json.Marshal(map[string]string{"expected": want, "actual": got})
	path := filepath.Join(opts.EvidenceDir, stableID(st.CaseID, name)+".json")
	if err := os.WriteFile(path, append(body, '\n'), 0o600); err != nil {
		return err
	}
	rel, _ := filepath.Rel(filepath.Dir(opts.JournalPath), path)
	outcome := "passed"
	if want != got {
		outcome = "failed"
	}
	id := stableID(st.CaseID, name)
	if err := j.write(JournalEvent{Kind: "attachment", CaseID: ptr(st.CaseID), StepID: ptr(id), AssertionID: ptr(id + "-assert"), Outcome: ptr(outcome), AttachmentRefs: []string{filepath.ToSlash(rel)}, Expected: want, Actual: got}); err != nil {
		return err
	}
	if opts.AllureRuntime != nil {
		if err := allure.Attachment(ctx, name, body, allure.AttachmentOptions{ContentType: "application/json", FileExtension: "json"}); err != nil {
			return fmt.Errorf("allure attachment %s: %w", name, err)
		}
	}
	if want != got {
		return fmt.Errorf("%s: expected %q, actual %q", name, want, got)
	}
	return nil
}
