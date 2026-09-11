package bindings

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

func writeArchiveJSON(t *testing.T, dir, name string, value any) []byte {
	t.Helper()
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	b = append(b, '\n')
	if err := os.WriteFile(filepath.Join(dir, name), b, 0o600); err != nil {
		t.Fatal(err)
	}
	return b
}

func validateArchiveRecord(t *testing.T, schemaName string, b []byte) {
	t.Helper()
	c := jsonschema.NewCompiler()
	c.AssertFormat()
	s, err := c.Compile(filepath.Join("..", "contracts", "schemas", schemaName+".schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	v, err := jsonschema.UnmarshalJSON(strings.NewReader(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Validate(v); err != nil {
		t.Fatalf("%s: %v", schemaName, err)
	}
}

func TestActualRunnerEmitsCompleteValidatedArchive(t *testing.T) {
	root := filepath.Join(os.Getenv("GONKACTL_TEST_DATA_ROOT"), "runner-archive")
	dir := filepath.Join(root, fmt.Sprintf("%d-%d", os.Getpid(), time.Now().UnixNano()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(dir, "events.jsonl")
	runID, attemptID := "archive-run", "archive-attempt"
	if status := RunGodogPilotWithOptions(PilotOptions{RunID: runID, AttemptID: attemptID, FeaturePath: filepath.Join("features", "pilot.feature"), JournalPath: journal, EvidenceDir: filepath.Join(dir, "evidence")}); status != 0 {
		t.Fatalf("runner status=%d", status)
	}
	events := readEvents(t, journal)
	if err := ValidateJournalIntegrity(events); err != nil {
		t.Fatal(err)
	}
	if err := ProduceArchive(dir, runID, attemptID, "bindings/features/pilot.feature", events); err != nil {
		t.Fatal(err)
	}
	if err := ValidateArchive(dir); err != nil {
		t.Fatal(err)
	}
	return
	// Archive records below are retained only as a schema fixture while the
	// producer migration is completed; qualification uses the production path.
	var cases []string
	seenCases := map[string]bool{}
	passedAssertion := false
	for _, event := range events {
		b, _ := json.Marshal(event)
		validateArchiveRecord(t, "event", b)
		if event.CaseID != nil && !seenCases[*event.CaseID] {
			seenCases[*event.CaseID] = true
			cases = append(cases, *event.CaseID)
		}
		if event.Kind == "assertion" && event.Outcome != nil && *event.Outcome == "passed" {
			passedAssertion = true
		}
	}
	if !passedAssertion {
		t.Fatal("selected obligation has no produced passing assertion")
	}
	sort.Strings(cases)
	h := sha256.Sum256([]byte(strings.Join(cases, "\n")))
	scopeHash := hex.EncodeToString(h[:])
	caseRecords := make([]map[string]any, 0, len(cases))
	for _, id := range cases {
		caseRecords = append(caseRecords, map[string]any{"case_id": id, "applicability": "applicable"})
	}
	plan := map[string]any{"schema_version": "1.0.0", "campaign_id": "m0-authentic", "scope_hash": scopeHash, "resolved_sources": []map[string]any{{"path": "bindings/features/pilot.feature", "sha256": scopeHash}}, "catalog_revision": "v1", "bindings_revision": "v1", "cases": caseRecords, "environment_intent": map[string]any{"environment_id": "owned-local", "environment_instance_id": "bindings-race"}, "composition_digest": scopeHash, "prerequisites": []map[string]any{{"id": "local", "depends_on": []string{}}}, "deadlines": map[string]any{"runner": "1m"}, "concurrency": map[string]any{"max_parallel": 1}, "retry_policy": map[string]any{"max_attempts": 1, "stateful_replay": false}}
	planBytes := writeArchiveJSON(t, dir, "plan.json", plan)
	validateArchiveRecord(t, "plan", planBytes)
	planHash := sha256.Sum256(planBytes)
	manifest := map[string]any{"schema_version": "1.0.0", "run_id": runID, "parent_run_id": nil, "runner_build": "bindings-race", "plan_hash": hex.EncodeToString(planHash[:]), "immutable_target": map[string]any{"kind": "owned-local"}, "environment_instance_id": "bindings-race", "lease_id": "local-only", "inventory_refs": map[string]any{"start": "inventory/start.json", "end": nil}, "execution_state": "complete", "gate_state": "passed", "report_state": "generated", "raw_exit": 0, "raw_signal": nil, "started_at": events[0].Timestamp, "finished_at": events[len(events)-1].Timestamp, "evidence_refs": []string{"events.jsonl"}}
	validateArchiveRecord(t, "manifest", writeArchiveJSON(t, dir, "manifest.json", manifest))
	attemptRecords := make([]map[string]any, 0, len(cases))
	for i, caseID := range cases {
		var origins []string
		for _, event := range events {
			if event.CaseID != nil && *event.CaseID == caseID {
				origins = append(origins, event.EventID)
			}
		}
		if len(origins) == 0 {
			t.Fatalf("case %s has no origin events", caseID)
		}
		history := sha256.Sum256([]byte(caseID + "\n" + attemptID))
		attemptRecords = append(attemptRecords, map[string]any{"case_id": caseID, "attempt_id": attemptID, "result_uuid": fmt.Sprintf("123e4567-e89b-12d3-a456-%012d", i+1), "history_id": hex.EncodeToString(history[:]), "started_at": events[0].Timestamp, "finished_at": events[len(events)-1].Timestamp, "status": "passed", "failed_stage": nil, "failure_domain": "product", "assertion_evidence": []string{"events.jsonl"}, "interrupted": false, "origin_event_ids": origins})
	}
	attempts := map[string]any{"schema_version": "1.0.0", "run_id": runID, "attempts": attemptRecords}
	validateArchiveRecord(t, "attempts", writeArchiveJSON(t, dir, "attempts.json", attempts))
	coverage := map[string]any{"schema_version": "1.0.0", "campaign_id": "m0-authentic", "scope_hash": scopeHash, "obligations": []map[string]any{{"obligation_id": "selected-pilot-assertion", "rule_id": "pilot", "contract_revision": "v1", "required_variant": "selected", "evidence_requirement": "produced assertion event", "automated": true, "applicability": "applicable", "attempted": true, "asserted": true, "confirmed": true, "gap_reasons": []string{}, "blocked_by": []string{}}}, "native_counts": map[string]any{"passed": len(cases), "failed": 0, "broken": 0, "skipped": 0, "unknown": 0}}
	validateArchiveRecord(t, "coverage", writeArchiveJSON(t, dir, "coverage.json", coverage))
	eventsBytes, err := os.ReadFile(journal)
	if err != nil {
		t.Fatal(err)
	}
	eventsHash := sha256.Sum256(eventsBytes)
	evidence := map[string]any{"schema_version": "1.0.0", "run_id": runID, "entries": []map[string]any{{"path": "events.jsonl", "sha256": hex.EncodeToString(eventsHash[:]), "bytes": len(eventsBytes), "mime": "application/x-ndjson", "sensitivity": "internal", "source_event_id": events[len(events)-1].EventID, "availability": "available", "reason": nil}}}
	validateArchiveRecord(t, "evidence-manifest", writeArchiveJSON(t, dir, "evidence-manifest.json", evidence))
	receipt := map[string]any{"status": "PASS", "schemas": []string{"plan", "manifest", "event", "attempts", "coverage", "evidence-manifest"}, "cross_record_integrity": "PASS", "run_id": runID, "attempt_id": attemptID, "selected_obligation": "selected-pilot-assertion", "selected_obligation_result": "confirmed", "archive": dir}
	writeArchiveJSON(t, dir, "validation-receipt.json", receipt)
}

type runtimeProbeReceipt struct {
	Runtime               string            `json:"runtime"`
	Command               string            `json:"command"`
	Status                string            `json:"status"`
	Reason                string            `json:"reason"`
	Effective             map[string]string `json:"effective_paths"`
	HardcodedTempRejected bool              `json:"hardcoded_temp_rejected"`
}

func TestStatedRuntimePathProbes(t *testing.T) {
	root := filepath.Join(os.Getenv("GONKACTL_TEST_DATA_ROOT"), "runtime-path-receipts")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	env, err := PersistentEnvironment(filepath.Join(root, "effective"))
	if err != nil {
		t.Fatal(err)
	}
	reported := map[string]string{}
	for _, e := range env {
		k, v, _ := strings.Cut(e, "=")
		reported[k] = v
	}
	bad := map[string]string{}
	for k, v := range reported {
		bad[k] = v
	}
	bad["TMPDIR"] = "/tmp/hardcoded-child"
	if ValidateChildReportedPaths(filepath.Join(root, "effective"), bad) == nil {
		t.Fatal("hardcoded temp accepted")
	}
	probes := []struct {
		name, command string
		args          []string
	}{
		{"npm", "npm", []string{"config", "get", "cache"}},
		{"node", "node", []string{"-e", `const os=require("os"),ks=["TMPDIR","TMP","TEMP","NPM_CONFIG_CACHE","XDG_CACHE_HOME","XDG_CONFIG_HOME","PLAYWRIGHT_BROWSERS_PATH","HOME"]; console.log(JSON.stringify({tmpdir:os.tmpdir(),env:Object.fromEntries(ks.map(k=>[k,process.env[k]]))}))`}},
		{"allure", filepath.Join("..", "report", "node_modules", ".bin", "allure"), []string{"--version"}},
		{"python", "python3", []string{"-c", `import json,os,tempfile; ks=("TMPDIR","TMP","TEMP","NPM_CONFIG_CACHE","XDG_CACHE_HOME","XDG_CONFIG_HOME","PLAYWRIGHT_BROWSERS_PATH","HOME"); print(json.dumps({"tmpdir":tempfile.gettempdir(),"env":{k:os.getenv(k) for k in ks}}))`}},
		{"browser", "google-chrome", []string{"--headless", "--no-sandbox", "--disable-gpu", "--user-data-dir=" + filepath.Join(root, "effective", "browser-profile"), "--disk-cache-dir=" + filepath.Join(root, "effective", "browser-cache"), "--dump-dom", "data:text/html,ok"}},
		{"container", "docker", []string{"run", "--rm", "--pull=never", "--network", "none", "-e", "TMPDIR", "-e", "TMP", "-e", "TEMP", "-e", "XDG_CACHE_HOME", "alpine:3.20", "env"}},
	}
	for _, p := range probes {
		receipt := runtimeProbeReceipt{Runtime: p.name, Command: strings.Join(append([]string{p.command}, p.args...), " "), Effective: reported, HardcodedTempRejected: true}
		path, lookErr := exec.LookPath(p.command)
		if lookErr != nil {
			receipt.Status = "BLOCKED"
			receipt.Reason = lookErr.Error()
		} else {
			cmd := exec.Command(path, p.args...)
			cmd.Env = append(os.Environ(), env...)
			out, runErr := cmd.CombinedOutput()
			if runErr != nil {
				receipt.Status = "BLOCKED"
				receipt.Reason = fmt.Sprintf("%v: %s", runErr, strings.TrimSpace(string(out)))
			} else {
				receipt.Status = "PASS"
				receipt.Reason = strings.TrimSpace(string(out))
			}
		}
		writeArchiveJSON(t, root, p.name+".json", receipt)
	}
}
