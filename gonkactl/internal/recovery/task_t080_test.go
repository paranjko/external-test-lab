package recovery

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/config"
)

func TestTask_T080(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	private := ed25519.NewKeyFromSeed(seed)
	payload := []byte(`{"immutable":true}`)
	message := approvalMessage(payload)
	signature := ed25519.Sign(private, message)
	if err := VerifyApproval(payload, hex.EncodeToString(signature), private.Public().(ed25519.PublicKey)); err != nil {
		t.Fatal(err)
	}
	if err := VerifyApproval([]byte(`{"immutable":false}`), hex.EncodeToString(signature), private.Public().(ed25519.PublicKey)); err == nil {
		t.Fatal("mutated payload accepted")
	}
	if RuntimeQualification("pass", "short") || !RuntimeQualification("pass", string(make([]byte, 64))) {
		t.Fatal("runtime qualification predicate")
	}
	validator, err := config.NewValidator()
	if err != nil {
		t.Fatalf("embedded canonical schema aliases: %v", err)
	}
	for _, ref := range []string{"runtime.schema.json#/$defs/journal", "runtime.schema.json#/$defs/transaction_intent"} {
		if err := validator.Validate(ref, json.RawMessage(`{}`)); err == nil || strings.Contains(err.Error(), "unknown local schema") {
			t.Fatalf("registered %s validation=%v", ref, err)
		}
	}
}

func approvalMessage(payload []byte) []byte {
	// Keep the test's signing input identical to the documented verification algorithm.
	return []byte("gonkactl-recovery-approval-v1:\n" + sha256hex(payload))
}

func sha256hex(payload []byte) string {
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}
