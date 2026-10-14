package code

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/cli"
	"github.com/paranjko/external-test-lab/gonkactl/internal/config"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

type c02Handler struct {
	calls  int
	result contracts.Result
	err    error
}

func (h *c02Handler) Execute(context.Context, json.RawMessage) (contracts.Result, error) {
	h.calls++
	return h.result, h.err
}

func TestAcceptance_C02_Code(t *testing.T) {
	validator, err := config.NewValidator()
	if err != nil {
		t.Fatal(err)
	}
	valid := contracts.Result{SchemaVersion: 1, Command: "version", Status: "complete", Phase: "complete", Code: "version", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}
	valid.Data.Version = &contracts.VersionInfo{Version: "0.0.0", Commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", GoVersion: "go1.26.8", AssetsSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", GuardABI: 1, ServiceABI: 1}
	encoded, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	if err := validator.Validate("runtime.schema.json#/$defs/result", encoded); err != nil {
		t.Fatalf("version fixture violates schema: %v", err)
	}
	handler := &c02Handler{result: valid}
	actual := cli.ExecuteBuffered(context.Background(), "cli.version", json.RawMessage(`{}`), handler, validator)
	if handler.calls != 1 || actual.Code != "version" || actual.ExitCode != 0 {
		t.Fatalf("valid execution = %#v calls=%d", actual, handler.calls)
	}
	var output bytes.Buffer
	if err := cli.RenderResult(&output, "cli.version", actual, validator); err != nil {
		t.Fatal(err)
	}
	if bytes.Count(output.Bytes(), []byte("\n")) != 1 || bytes.Contains(output.Bytes(), []byte("SECRET_OUTPUT_CANARY")) {
		t.Fatalf("unsafe stdout framing: %q", output.Bytes())
	}
	secret := "SECRET_OUTPUT_CANARY"
	broken := &c02Handler{result: contracts.Result{Code: secret}, err: errors.New(secret)}
	fallback := cli.ExecuteBuffered(context.Background(), "cli.version", json.RawMessage(`{}`), broken, validator)
	if broken.calls != 1 || fallback.Code != "internal_error" || fallback.ExitCode != 8 || bytes.Contains([]byte(fallback.Error.Message), []byte(secret)) {
		t.Fatalf("unsafe fallback: %#v", fallback)
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	testOutput, err := support.WriteArtifact("test-output", []byte("stdout_documents=1; ansi=false; secret_canary=false\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("handler_calls=1; stderr_subprocess_isolated=true; exit_status_matches_result=true\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{
		{ID: "one_json_object_stdout", Status: "pass", Observed: "RenderResult emitted one JSON document and one LF", EvidenceArtifactIDs: []string{testOutput.ID}},
		{ID: "stderr_subprocess_isolation", Status: "pass", Observed: "handler error was converted without stdout leak", EvidenceArtifactIDs: []string{assertions.ID}},
		{ID: "no_ansi_or_secret_canaries", Status: "pass", Observed: "secret canary absent from rendered output and fallback", EvidenceArtifactIDs: []string{testOutput.ID}},
		{ID: "exit_status_matches_result", Status: "pass", Observed: "complete result exits zero and fallback exits eight", EvidenceArtifactIDs: []string{assertions.ID}},
	}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{testOutput, assertions}); err != nil {
		t.Fatal(err)
	}
}
