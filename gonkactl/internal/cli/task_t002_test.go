package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/config"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type recordingHandler struct {
	calls  int
	result contracts.Result
	err    error
}

func (h *recordingHandler) Execute(context.Context, json.RawMessage) (contracts.Result, error) {
	h.calls++
	return h.result, h.err
}

type acceptingValidator struct{}

func (acceptingValidator) Validate(string, json.RawMessage) error { return nil }

func TestTask_T002(t *testing.T) {
	validator, err := config.NewValidator()
	if err != nil {
		t.Fatalf("NewValidator() = %v", err)
	}
	if err := validator.Validate("runtime.schema.json#/$defs/result", json.RawMessage(`{"schema_version":1,"schema_version":1}`)); err == nil {
		t.Fatal("duplicate JSON keys must be rejected before schema validation")
	}
	secret := "SECRET_OUTPUT_CANARY"
	handler := &recordingHandler{result: contracts.Result{Code: secret}, err: errors.New(secret)}
	result := ExecuteBuffered(context.Background(), "cli.version", json.RawMessage(`{}`), handler, acceptingValidator{})
	if handler.calls != 1 {
		t.Fatalf("handler calls = %d, want 1", handler.calls)
	}
	if result.Code != "internal_error" || result.ExitCode != 8 || result.Error == nil || result.Error.Message == secret {
		t.Fatalf("unexpected fallback: %#v", result)
	}
	if err := RenderResult(&bytes.Buffer{}, "cli.version", contracts.Result{}, acceptingValidator{}); err == nil {
		t.Fatal("zero result must not render")
	}
	valid := contracts.Result{SchemaVersion: 1, Command: "version", Status: "complete", Phase: "complete", Code: "version", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}
	valid.Data.Version = &contracts.VersionInfo{Version: "devel", Commit: "unknown", GoVersion: "go1.26.8", AssetsSHA256: "unknown", GuardABI: 1, ServiceABI: 1}
	var out bytes.Buffer
	if err := RenderResult(&out, "cli.version", valid, acceptingValidator{}); err != nil {
		t.Fatal(err)
	}
	if bytes.Count(out.Bytes(), []byte("\n")) != 1 || !bytes.HasSuffix(out.Bytes(), []byte("\n")) {
		t.Fatalf("output framing = %q", out.Bytes())
	}
}
