package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestNewRootTrustPolicyUsesCurrentClock(t *testing.T) {
	trustPolicy := `{"schema_version":"local-trust/v1","roots":[{"key_id":"root-1","role":"operator","scopes":["capture"],"public_key_hex":"0000000000000000000000000000000000000000000000000000000000000000"}],"revocations":{"valid_until":"2099-01-01T00:00:00Z","revoked":[]}}`
	path := filepath.Join(t.TempDir(), "trust-policy.json")
	if err := os.WriteFile(path, []byte(trustPolicy), 0o600); err != nil {
		t.Fatal(err)
	}

	root := NewRoot()
	root.SetArgs([]string{"recover", contract.Scenario, "inspect", "--trust-policy", path})
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&output)
	err := root.Execute()
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatalf("decode outcome: %v\n%s", err, output.String())
	}
	var exit *ExitError
	if err != nil && (!errors.As(err, &exit) || exit.Code != 2) {
		t.Fatalf("expected normal inspect validation refusal, got %v", err)
	}
	if outcome.Code != "offline_preview_only" && outcome.Code != "input_validation_refused" {
		t.Fatalf("trust policy did not reach normal inspect validation: %+v", outcome)
	}
	if outcome.Code == "input_validation_refused" && (err == nil || exit.Code != 2) {
		t.Fatalf("expected normal inspect validation exit 2, got %v", err)
	}
}
