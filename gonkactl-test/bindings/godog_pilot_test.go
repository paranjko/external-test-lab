package bindings

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	allureruntime "github.com/allure-framework/allure-go/commons/runtime"
	"github.com/santhosh-tekuri/jsonschema/v6"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type runtimeRecorder struct {
	mu       sync.Mutex
	messages []allureruntime.Message
}

func (r *runtimeRecorder) Handle(_ context.Context, m allureruntime.Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.messages = append(r.messages, m)
	return nil
}
func ownedPath(t *testing.T, name string) string {
	t.Helper()
	root := os.Getenv("GONKACTL_TEST_DATA_ROOT")
	if root == "" {
		t.Fatal("GONKACTL_TEST_DATA_ROOT is required")
	}
	p := filepath.Join(root, "bindings-test", t.Name(), fmt.Sprintf("%d-%d", os.Getpid(), time.Now().UnixNano()), name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}
func readEvents(t *testing.T, path string) []JournalEvent {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []JournalEvent
	s := bufio.NewScanner(f)
	for s.Scan() {
		var e JournalEvent
		if err := json.Unmarshal(s.Bytes(), &e); err != nil {
			t.Fatal(err)
		}
		out = append(out, e)
	}
	if err := s.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}
func TestGodogPilotRecordsSchemaIdentityAndAllure(t *testing.T) {
	journal := ownedPath(t, "events.jsonl")
	rec := &runtimeRecorder{}
	opts := PilotOptions{RunID: "run-1", AttemptID: "attempt-1", FeaturePath: filepath.Join("features", "pilot.feature"), JournalPath: journal, EvidenceDir: ownedPath(t, "evidence"), AllureRuntime: rec}
	if status := RunGodogPilotWithOptions(opts); status != 0 {
		t.Fatalf("status=%d", status)
	}
	events := readEvents(t, journal)
	compiler := jsonschema.NewCompiler()
	compiler.AssertFormat()
	schema, err := compiler.Compile(filepath.Join("..", "contracts", "schemas", "event.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	lastSeq := int64(0)
	lastElapsed := int64(0)
	cases := map[string]bool{}
	attachments := 0
	for _, e := range events {
		encoded, _ := json.Marshal(e)
		value, decodeErr := jsonschema.UnmarshalJSON(strings.NewReader(string(encoded)))
		if decodeErr != nil {
			t.Fatal(decodeErr)
		}
		if err := schema.Validate(value); err != nil {
			t.Fatalf("produced event violates v1 schema: %s: %v", encoded, err)
		}
		if e.SchemaVersion != "1.0.0" || e.RunID != "run-1" || e.EventID == "" {
			t.Fatalf("incomplete event: %+v", e)
		}
		if seen[e.EventID] {
			t.Fatalf("duplicate event id %s", e.EventID)
		}
		seen[e.EventID] = true
		if e.Sequence != lastSeq+1 || e.ElapsedMS < lastElapsed {
			t.Fatalf("non-monotonic event: %+v", e)
		}
		lastSeq = e.Sequence
		lastElapsed = e.ElapsedMS
		if e.CaseID != nil {
			cases[*e.CaseID] = true
		}
		if e.Kind == "attachment" {
			attachments++
			if e.Expected == nil || e.Actual == nil || len(e.AttachmentRefs) == 0 {
				t.Fatalf("weak assertion event: %+v", e)
			}
		}
	}
	if len(cases) != 3 {
		t.Fatalf("want 3 distinct expanded cases, got %v", cases)
	}
	if attachments < 4 {
		t.Fatalf("want assertion attachments, got %d", attachments)
	}
	if len(rec.messages) == 0 {
		t.Fatal("official Allure SDK emitted no messages")
	}
	if err := ValidateJournalIntegrity(events); err != nil {
		t.Fatal(err)
	}
}

func TestConcurrentPilotAttemptsKeepIndependentJournals(t *testing.T) {
	t.Parallel()
	type result struct {
		status int
		journalPath string
		runID       string
		attemptID    string
	}
	results := make(chan result, 2)
	for i := 1; i <= 2; i++ {
		i := i
		go func() {
			runID := fmt.Sprintf("concurrent-run-%d", i)
			attemptID := fmt.Sprintf("concurrent-attempt-%d", i)
			journalPath := ownedPath(t, "events.jsonl")
			status := RunGodogPilotWithOptions(PilotOptions{
				RunID: runID, AttemptID: attemptID,
				FeaturePath: filepath.Join("features", "pilot.feature"),
				JournalPath: journalPath, EvidenceDir: ownedPath(t, "evidence"),
			})
			results <- result{status: status, journalPath: journalPath, runID: runID, attemptID: attemptID}
		}()
	}
	for i := 1; i <= 2; i++ {
		r := <-results
		if r.status != 0 {
			t.Fatalf("concurrent pilot status=%d", r.status)
		}
		events := readEvents(t, r.journalPath)
		if err := ValidateJournalIntegrity(events); err != nil {
			t.Fatalf("concurrent journal integrity: %v", err)
		}
		if len(events) == 0 {
			t.Fatal("concurrent pilot produced empty journal")
		}
		// Every journal is an isolated attempt: no event may be attributed to
		// the other run, and all case events carry this attempt's identity.
		var runID, attemptID string
		for _, e := range events {
			if runID == "" { runID = e.RunID }
			if e.RunID != r.runID { t.Fatalf("event attributed to %q, want %q", e.RunID, r.runID) }
			if e.RunID != runID {
				t.Fatalf("journal mixed run IDs: %q and %q", runID, e.RunID)
			}
			if e.AttemptID != nil {
				if attemptID == "" { attemptID = *e.AttemptID }
				if *e.AttemptID != r.attemptID { t.Fatalf("event attributed to attempt %q, want %q", *e.AttemptID, r.attemptID) }
				if *e.AttemptID != attemptID {
					t.Fatalf("journal mixed attempt IDs: %q and %q", attemptID, *e.AttemptID)
				}
			}
		}
		if attemptID == "" {
			t.Fatal("concurrent journal omitted attempt identity")
		}
	}
}

func TestJournalIntegrityFailsClosedOnUnknownAndDuplicateIDs(t *testing.T) {
	caseID := "case-1"
	base := JournalEvent{EventID: "e1", Sequence: 1, ElapsedMS: 1, Kind: "case_started", CaseID: &caseID}
	duplicate := base
	duplicate.Sequence = 2
	if err := ValidateJournalIntegrity([]JournalEvent{base, duplicate}); err == nil {
		t.Fatal("duplicate case id accepted")
	}
	unknown := "missing"
	if err := ValidateJournalIntegrity([]JournalEvent{{EventID: "e1", Sequence: 1, Kind: "assertion", CaseID: &unknown}}); err == nil {
		t.Fatal("unknown case id accepted")
	}
}

func TestUndefinedAmbiguousPendingHookPanicAndCancellationStopExecution(t *testing.T) {
	cases := map[string]string{"undefined": "неизвестный шаг", "ambiguous": "неоднозначный шаг", "pending": "ожидает реализации", "hook": "стенд подготовлен", "panic": "паника шага", "cancel": "отмена шага"}
	for name, step := range cases {
		t.Run(name, func(t *testing.T) {
			scenario := "Control"
			if name == "hook" {
				scenario = "Hook failure"
			}
			feature := ownedPath(t, "control.feature")
			contents := "# language: ru\nФункция: Controls\n  Сценарий: " + scenario + "\n    Допустим " + step + "\n"
			if err := os.WriteFile(feature, []byte(contents), 0o600); err != nil {
				t.Fatal(err)
			}
			journal := ownedPath(t, "events.jsonl")
			status := RunGodogPilotWithOptions(PilotOptions{RunID: "run-" + name, AttemptID: "attempt-" + name, FeaturePath: feature, JournalPath: journal, EvidenceDir: ownedPath(t, "evidence"), EnableAmbiguousDefinitions: name == "ambiguous"})
			if status == 0 {
				t.Fatalf("%s control executed successfully", name)
			}
			events := readEvents(t, journal)
			if err := ValidateJournalIntegrity(events); err != nil {
				t.Fatalf("%s journal: %v", name, err)
			}
			terminal := false
			for _, e := range events {
				if e.Kind == "case_finished" && e.CaseID != nil && *e.CaseID != "unknown" && e.Outcome != nil && *e.Outcome != "passed" {
					terminal = true
				}
			}
			if !terminal {
				t.Fatalf("%s lacks explicit non-pass terminal case", name)
			}
		})
	}
}

func TestRunnerJournalWriteFailureHasInterruptedReceipt(t *testing.T) {
	feature := filepath.Join("features", "pilot.feature")
	journal := ownedPath(t, "events.jsonl")
	status := RunGodogPilotWithOptions(PilotOptions{RunID: "run-write-loss", AttemptID: "attempt-write-loss", FeaturePath: feature, JournalPath: journal, EvidenceDir: ownedPath(t, "evidence"), FailJournalAfter: 3})
	if status != 2 {
		t.Fatalf("status=%d", status)
	}
	contents, err := os.ReadFile(journal + ".receipt.json")
	if err != nil {
		t.Fatal(err)
	}
	var receipt map[string]any
	if err := json.Unmarshal(contents, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt["outcome"] != "interrupted" || !strings.Contains(receipt["reason"].(string), "journal write failure") {
		t.Fatalf("receipt=%v", receipt)
	}
}
func TestFixtureChangeFailsReachedAssertion(t *testing.T) {
	journal := ownedPath(t, "events.jsonl")
	status := RunGodogPilotWithOptions(PilotOptions{RunID: "run-broken", AttemptID: "attempt-broken", FeaturePath: filepath.Join("features", "fixture_failure.feature"), JournalPath: journal, EvidenceDir: ownedPath(t, "evidence")})
	if status == 0 {
		t.Fatal("changed fixture response passed")
	}
	found := false
	for _, e := range readEvents(t, journal) {
		if e.Kind == "attachment" && e.Outcome != nil && *e.Outcome == "failed" && e.Expected == "ok" && e.Actual == "error" {
			found = true
		}
	}
	if !found {
		t.Fatal("missing expected/actual failed assertion")
	}
}
func TestGodogGivenFailureDoesNotFabricateLaterPass(t *testing.T) {
	journal := ownedPath(t, "events.jsonl")
	if status := RunGodogPilotWithOptions(PilotOptions{RunID: "run-given", AttemptID: "attempt-given", FeaturePath: filepath.Join("features", "failure.feature"), JournalPath: journal, EvidenceDir: ownedPath(t, "evidence")}); status == 0 {
		t.Fatal("failing Given returned success")
	}
	for _, e := range readEvents(t, journal) {
		if e.Kind == "attachment" && e.Outcome != nil && *e.Outcome == "passed" {
			t.Fatalf("unreached assertion fabricated: %+v", e)
		}
	}
}
func TestJournalRejectsReuseAndWriteFailure(t *testing.T) {
	path := ownedPath(t, "events.jsonl")
	opts := PilotOptions{RunID: "run-a", AttemptID: "attempt-a", JournalPath: path}
	j, err := newJournal(opts)
	if err != nil {
		t.Fatal(err)
	}
	if err := j.close("passed"); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(path)
	if _, err := newJournal(opts); err == nil {
		t.Fatal("reused journal accepted")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("reused path was destructively changed")
	}
	bad := ownedPath(t, "bad.jsonl")
	j, err = newJournal(PilotOptions{RunID: "run-b", AttemptID: "attempt-b", JournalPath: bad})
	if err != nil {
		t.Fatal(err)
	}
	if err := j.file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := j.write(JournalEvent{Kind: "interrupted"}); err == nil {
		t.Fatal("closed journal write reported success")
	}
}
func TestPersistentPathsRejectSystemTempAndCoverChildren(t *testing.T) {
	for _, p := range []string{"/tmp/x", "/var/tmp/x", "relative"} {
		if err := ValidatePersistentPath(p); err == nil {
			t.Fatalf("accepted %s", p)
		}
	}
	root := filepath.Join(os.Getenv("GONKACTL_TEST_DATA_ROOT"), "child-env")
	env, err := PersistentEnvironment(root)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(env, "\n")
	reported := map[string]string{}
	for _, key := range persistentEnv {
		if !strings.Contains(joined, key+"="+root) {
			t.Fatalf("missing %s in %s", key, joined)
		}
		for _, entry := range env {
			if strings.HasPrefix(entry, key+"=") {
				reported[key] = strings.TrimPrefix(entry, key+"=")
			}
		}
	}
	if err := ValidateChildReportedPaths(root, reported); err != nil {
		t.Fatal(err)
	}
	reported["TMPDIR"] = "/tmp/hardcoded-child"
	if err := ValidateChildReportedPaths(root, reported); err == nil {
		t.Fatal("hardcoded child /tmp usage accepted")
	}
}

func TestActualChildEnvironmentReceiptAndHardcodedTempControl(t *testing.T) {
	if os.Getenv("GONKACTL_CHILD_ENV_PROBE") != "" {
		for _, key := range persistentEnv {
			value := os.Getenv(key)
			if os.Getenv("GONKACTL_CHILD_ENV_PROBE") == "hardcoded-temp" && key == "TMPDIR" {
				value = "/tmp/hardcoded-child"
			}
			fmt.Printf("%s=%s\n", key, value)
		}
		os.Exit(0)
	}
	root := filepath.Join(os.Getenv("GONKACTL_TEST_DATA_ROOT"), "actual-child-env")
	t.Setenv("GONKACTL_CHILD_ENV_PROBE", "persistent")
	receipt, err := ProbeChildEnvironment(context.Background(), root, os.Args[0], "-test.run=^TestActualChildEnvironmentReceiptAndHardcodedTempControl$")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(receipt); err != nil {
		t.Fatalf("missing actual-child receipt %s: %v", receipt, err)
	}
	t.Setenv("GONKACTL_CHILD_ENV_PROBE", "hardcoded-temp")
	negativeReceipt, err := ProbeChildEnvironment(context.Background(), root, os.Args[0], "-test.run=^TestActualChildEnvironmentReceiptAndHardcodedTempControl$")
	if err == nil || !strings.Contains(err.Error(), "forbidden temporary path") {
		t.Fatalf("hardcoded child temp control err=%v", err)
	}
	contents, readErr := os.ReadFile(negativeReceipt)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !strings.Contains(string(contents), `"TMPDIR": "/tmp/hardcoded-child"`) || !strings.Contains(string(contents), `"valid": false`) {
		t.Fatalf("negative receipt did not retain hardcoded temp: %s", contents)
	}
}
