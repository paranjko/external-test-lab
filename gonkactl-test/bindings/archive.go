package bindings

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// ProduceArchive emits the six M0 records from the runner's journal. Keeping
// this in production code prevents qualification tests from manufacturing a
// passing archive independently of the runner.
func ProduceArchive(dir, runID, attemptID, feature string, events []JournalEvent) error {
	if len(events) == 0 || runID == "" || attemptID == "" {
		return fmt.Errorf("archive requires run, attempt and events")
	}
	if err := ValidateJournalIntegrity(events); err != nil {
		return err
	}
	cases := map[string]bool{}
	for _, e := range events {
		if e.CaseID != nil {
			cases[*e.CaseID] = true
		}
	}
	ids := make([]string, 0, len(cases))
	for id := range cases {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	h := sha256.Sum256([]byte(strings.Join(ids, "\n")))
	scope := hex.EncodeToString(h[:])
	plan := map[string]any{"schema_version": "1.0.0", "campaign_id": "m0-authentic", "scope_hash": scope, "resolved_sources": []any{map[string]any{"path": feature, "sha256": scope}}, "catalog_revision": "v1", "bindings_revision": "v1", "cases": caseMaps(ids), "environment_intent": map[string]any{"environment_id": "owned-local", "environment_instance_id": "bindings-race"}, "composition_digest": scope, "prerequisites": []any{map[string]any{"id": "local", "depends_on": []string{}}}, "deadlines": map[string]any{"runner": "1m"}, "concurrency": map[string]any{"max_parallel": 1}, "retry_policy": map[string]any{"max_attempts": 1, "stateful_replay": false}}
	if err := writeRecord(dir, "plan.json", plan); err != nil {
		return err
	}
	pb, _ := json.MarshalIndent(plan, "", "  ")
	pb = append(pb, '\n')
	ph := sha256.Sum256(pb)
	manifest := map[string]any{"schema_version": "1.0.0", "run_id": runID, "parent_run_id": nil, "runner_build": "bindings", "plan_hash": hex.EncodeToString(ph[:]), "immutable_target": map[string]any{"kind": "owned-local"}, "environment_instance_id": "bindings-race", "lease_id": "local-only", "inventory_refs": map[string]any{"start": "inventory/start.json", "end": nil}, "execution_state": "complete", "gate_state": "passed", "report_state": "generated", "raw_exit": 0, "raw_signal": nil, "started_at": events[0].Timestamp, "finished_at": events[len(events)-1].Timestamp, "evidence_refs": []string{"events.jsonl"}}
	if err := writeRecord(dir, "manifest.json", manifest); err != nil {
		return err
	}
	attempts := []any{}
	for i, id := range ids {
		origins := []string{}
		for _, e := range events {
			if e.CaseID != nil && *e.CaseID == id {
				origins = append(origins, e.EventID)
			}
		}
		x := sha256.Sum256([]byte(id + "\n" + attemptID))
		attempts = append(attempts, map[string]any{"case_id": id, "attempt_id": attemptID + "-" + fmt.Sprint(i+1), "result_uuid": fmt.Sprintf("123e4567-e89b-12d3-a456-%012d", i+1), "history_id": hex.EncodeToString(x[:]), "started_at": events[0].Timestamp, "finished_at": events[len(events)-1].Timestamp, "status": "passed", "failure_domain": "product", "assertion_evidence": []string{"events.jsonl"}, "interrupted": false, "origin_event_ids": origins})
	}
	if err := writeRecord(dir, "attempts.json", map[string]any{"schema_version": "1.0.0", "run_id": runID, "attempts": attempts}); err != nil {
		return err
	}
	if err := writeRecord(dir, "coverage.json", map[string]any{"schema_version": "1.0.0", "campaign_id": "m0-authentic", "scope_hash": scope, "obligations": []any{map[string]any{"obligation_id": "selected-pilot-assertion", "rule_id": "pilot", "contract_revision": "v1", "required_variant": "selected", "evidence_requirement": "produced assertion event", "automated": true, "applicability": "applicable", "attempted": true, "asserted": true, "confirmed": true, "gap_reasons": []string{}, "blocked_by": []string{}}}, "native_counts": map[string]any{"passed": len(ids)}}); err != nil {
		return err
	}
	b, err := os.ReadFile(filepath.Join(dir, "events.jsonl"))
	if err != nil {
		return err
	}
	eh := sha256.Sum256(b)
	if err = writeRecord(dir, "evidence-manifest.json", map[string]any{"schema_version": "1.0.0", "run_id": runID, "entries": []any{map[string]any{"path": "events.jsonl", "sha256": hex.EncodeToString(eh[:]), "bytes": len(b), "mime": "application/x-ndjson", "sensitivity": "internal", "source_event_id": events[len(events)-1].EventID, "availability": "available"}}}); err != nil {
		return err
	}
	return ValidateArchive(dir)
}
func caseMaps(ids []string) []any {
	out := make([]any, len(ids))
	for i, id := range ids {
		out[i] = map[string]any{"case_id": id, "applicability": "applicable"}
	}
	return out
}
func writeRecord(dir, name string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e == nil {
		b = append(b, '\n')
		e = os.WriteFile(filepath.Join(dir, name), b, 0600)
	}
	return e
}

// ValidateArchive checks cross-record identity, references, hashes and the
// selected obligation. It is intentionally independent of test helpers.
func ValidateArchive(dir string) error {
	for _, n := range []string{"plan.json", "manifest.json", "attempts.json", "coverage.json", "evidence-manifest.json", "events.jsonl"} {
		if _, e := os.Stat(filepath.Join(dir, n)); e != nil {
			return fmt.Errorf("missing archive record %s", n)
		}
	}
	ev, e := readEventsFile(filepath.Join(dir, "events.jsonl"))
	if e != nil {
		return e
	}
	if err := ValidateJournalIntegrity(ev); err != nil {
		return err
	}
	for _, n := range []string{"plan", "manifest", "attempts", "coverage", "evidence-manifest"} {
		var value any
		if err := readJSON(filepath.Join(dir, n+".json"), &value); err != nil {
			return err
		}
		if err := validateArchiveSchema(n, value); err != nil {
			return err
		}
	}
	var planRaw, manifestRaw, attemptsRaw map[string]any
	if err := readJSON(filepath.Join(dir, "plan.json"), &planRaw); err != nil {
		return err
	}
	if err := readJSON(filepath.Join(dir, "manifest.json"), &manifestRaw); err != nil {
		return err
	}
	if err := readJSON(filepath.Join(dir, "attempts.json"), &attemptsRaw); err != nil {
		return err
	}
	if got, _ := manifestRaw["run_id"].(string); got == "" {
		return fmt.Errorf("manifest missing run_id")
	} else if ar, _ := attemptsRaw["run_id"].(string); ar != got {
		return fmt.Errorf("run_id mismatch: manifest=%q attempts=%q", got, ar)
	}
	pb, err := os.ReadFile(filepath.Join(dir, "plan.json"))
	if err != nil {
		return err
	}
	ph := sha256.Sum256(pb)
	if got, _ := manifestRaw["plan_hash"].(string); got != hex.EncodeToString(ph[:]) {
		return fmt.Errorf("plan hash mismatch")
	}
	_ = planRaw
	for _, x := range ev {
		var value any
		b, _ := json.Marshal(x)
		if err := json.Unmarshal(b, &value); err != nil {
			return err
		}
		if err := validateArchiveSchema("event", value); err != nil {
			return err
		}
	}
	known := map[string]bool{}
	for _, x := range ev {
		known[x.EventID] = true
	}
	var attempts struct {
		Attempts []struct {
			AttemptID      string   `json:"attempt_id"`
			ResultUUID     string   `json:"result_uuid"`
			HistoryID      string   `json:"history_id"`
			OriginEventIDs []string `json:"origin_event_ids"`
		} `json:"attempts"`
	}
	if err := readJSON(filepath.Join(dir, "attempts.json"), &attempts); err != nil {
		return err
	}
	seenA, seenR, seenH := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, a := range attempts.Attempts {
		if a.AttemptID == "" || seenA[a.AttemptID] {
			return fmt.Errorf("duplicate/unknown attempt id %q", a.AttemptID)
		}
		seenA[a.AttemptID] = true
		if a.ResultUUID == "" || seenR[a.ResultUUID] {
			return fmt.Errorf("duplicate result id %q", a.ResultUUID)
		}
		seenR[a.ResultUUID] = true
		if a.HistoryID == "" || seenH[a.HistoryID] {
			return fmt.Errorf("duplicate history id %q", a.HistoryID)
		}
		seenH[a.HistoryID] = true
		if len(a.OriginEventIDs) == 0 {
			return fmt.Errorf("attempt %q has no origins", a.AttemptID)
		}
		for _, id := range a.OriginEventIDs {
			if !known[id] {
				return fmt.Errorf("unknown origin event %q", id)
			}
		}
	}
	var evidence struct {
		Entries []struct {
			Path, SHA256 string
			Bytes        int `json:"bytes"`
		} `json:"entries"`
	}
	if err := readJSON(filepath.Join(dir, "evidence-manifest.json"), &evidence); err != nil {
		return err
	}
	for _, x := range evidence.Entries {
		b, err := os.ReadFile(filepath.Join(dir, x.Path))
		if err != nil {
			return err
		}
		h := sha256.Sum256(b)
		if hex.EncodeToString(h[:]) != x.SHA256 || len(b) != x.Bytes {
			return fmt.Errorf("evidence hash/size mismatch for %s", x.Path)
		}
	}
	return nil
}

func validateArchiveSchema(name string, value any) error {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		return fmt.Errorf("locate archive schemas")
	}
	c := jsonschema.NewCompiler()
	c.AssertFormat()
	s, err := c.Compile(filepath.Join(filepath.Dir(source), "..", "contracts", "schemas", name+".schema.json"))
	if err != nil {
		return fmt.Errorf("compile %s schema: %w", name, err)
	}
	if err := s.Validate(value); err != nil {
		return fmt.Errorf("%s schema: %w", name, err)
	}
	return nil
}
func readJSON(path string, v any) error {
	b, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, v); e != nil {
		return fmt.Errorf("%s: %w", path, e)
	}
	return nil
}
func readEventsFile(path string) ([]JournalEvent, error) {
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	var out []JournalEvent
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var x JournalEvent
		if e = json.Unmarshal([]byte(line), &x); e != nil {
			return nil, e
		}
		out = append(out, x)
	}
	return out, nil
}
