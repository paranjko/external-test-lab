package bindings

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
}

func TestArchiveSchemaRejectsMutation(t *testing.T) {
	valid := map[string]any{"schema_version": "1.0.0", "run_id": "run", "attempts": []any{}}
	if err := validateArchiveSchema("attempts", valid); err != nil {
		t.Fatal(err)
	}
	valid["unexpected"] = true
	if err := validateArchiveSchema("attempts", valid); err == nil {
		t.Fatal("schema accepted unknown field")
	}
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
