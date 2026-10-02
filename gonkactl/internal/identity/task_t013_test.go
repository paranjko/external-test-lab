package identity

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"io"
	"strings"
	"testing"
)

type taskRunner struct {
	spec  contracts.ProcessSpec
	stdin string
}

func (r *taskRunner) Run(_ context.Context, s contracts.ProcessSpec) (contracts.ProcessResult, error) {
	r.spec = s
	input, _ := io.ReadAll(s.Stdin)
	r.stdin = string(input)
	if len(s.Args) > 13 && s.Args[len(s.Args)-5] == "show" {
		if s.Args[len(s.Args)-3] == "-a" && s.Args[len(s.Args)-4] == "cold" {
			return contracts.ProcessResult{Stdout: []byte("gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4\n")}, nil
		}
		if s.Args[len(s.Args)-3] == "-a" {
			return contracts.ProcessResult{Stdout: []byte("gonka16s0dp897vdfqvf02a00s9afdvrt70nm6pczf0c\n")}, nil
		}
		return contracts.ProcessResult{Stdout: []byte(`{"key":"A7lHeLlwbcHee+m9zpuU0CbxxIqP0A4ODIB3VSXbMGmy"}`)}, nil
	}
	return contracts.ProcessResult{}, nil
}
func TestTask_T013(t *testing.T) {
	h := NewPinnedMnemonicAccountVerificationHandler(contracts.Dependencies{})
	r, err := h.Execute(context.Background(), json.RawMessage(`{"mode":"offline"}`))
	if err != nil || r.Data.AccountDerivation == nil || *r.Data.AccountDerivation != "pending" {
		t.Fatalf("offline=%#v %v", r, err)
	}
	runner := &taskRunner{}
	h = NewPinnedMnemonicAccountVerificationHandler(contracts.Dependencies{Root: t.TempDir(), Runner: runner})
	cold := "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
	warm := "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
	r, err = h.Execute(context.Background(), json.RawMessage(`{"mode":"full","runtime_image":"`+PinnedInferencedImage+`","cold_mnemonic":"`+cold+`","warm_mnemonic":"`+warm+`","cold_address":"gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4","warm_address":"gonka16s0dp897vdfqvf02a00s9afdvrt70nm6pczf0c","warm_pubkey_b64":"A7lHeLlwbcHee+m9zpuU0CbxxIqP0A4ODIB3VSXbMGmy"}`))
	if err != nil || r.Status != "pass" {
		t.Fatalf("full=%#v %v", r, err)
	}
	if runner.spec.Executable != "docker" || runner.spec.Args[8] != PinnedInferencedImage {
		t.Fatalf("not pinned: %#v", runner.spec)
	}
	if password := strings.Split(runner.stdin, "\n")[0]; len(password) != 48 {
		t.Fatalf("generated password length = %d", len(password))
	}
}
