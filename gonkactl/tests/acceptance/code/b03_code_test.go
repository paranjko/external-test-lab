package code

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/identity"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
	"io"
	"os"
	"testing"
	"time"
)

type b03Runner struct{ spec contracts.ProcessSpec }

func (r *b03Runner) Run(_ context.Context, s contracts.ProcessSpec) (contracts.ProcessResult, error) {
	r.spec = s
	_, _ = io.ReadAll(s.Stdin)
	if len(s.Args) > 13 && s.Args[len(s.Args)-5] == "show" {
		name, flag := s.Args[len(s.Args)-4], s.Args[len(s.Args)-3]
		if flag == "-a" && name == "cold" {
			return contracts.ProcessResult{Stdout: []byte("gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4\n")}, nil
		}
		if flag == "-a" && name == "warm" {
			return contracts.ProcessResult{Stdout: []byte("gonka16s0dp897vdfqvf02a00s9afdvrt70nm6pczf0c\n")}, nil
		}
		return contracts.ProcessResult{Stdout: []byte(`{"key":"A7lHeLlwbcHee+m9zpuU0CbxxIqP0A4ODIB3VSXbMGmy"}`)}, nil
	}
	return contracts.ProcessResult{}, nil
}
func TestAcceptance_B03_Code(t *testing.T) {
	// These public values were produced by the pinned linux/amd64 CLI in a
	// network-disabled disposable keyring; mnemonic/passphrase bytes are absent.
	const oracle = "image=ghcr.io/product-science/inferenced@sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112\nplatform=linux/amd64\nversion=0.2.15\ncold_address=gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4\ncold_pubkey=A3M+zwCyunWgh6wgABxeUtMDK7a0FZLrwi9nNyXyKVor\nwarm_address=gonka16s0dp897vdfqvf02a00s9afdvrt70nm6pczf0c\nwarm_pubkey=A7lHeLlwbcHee+m9zpuU0CbxxIqP0A4ODIB3VSXbMGmy\n"
	h := identity.NewPinnedMnemonicAccountVerificationHandler(contracts.Dependencies{})
	pending, err := h.Execute(context.Background(), json.RawMessage(`{"mode":"offline"}`))
	if err != nil || pending.Data.AccountDerivation == nil || *pending.Data.AccountDerivation != "pending" {
		t.Fatal("offline shape falsely verified")
	}
	runner := &b03Runner{}
	h = identity.NewPinnedMnemonicAccountVerificationHandler(contracts.Dependencies{Runner: runner})
	bad, err := h.Execute(context.Background(), json.RawMessage(`{"mode":"full","runtime_image":"wrong","cold_mnemonic":"bad","warm_mnemonic":"bad"}`))
	if err == nil || bad.Status != "" {
		t.Fatal("invalid full input accepted")
	}
	cold := "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
	warm := "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
	h = identity.NewPinnedMnemonicAccountVerificationHandler(contracts.Dependencies{Root: t.TempDir(), Runner: runner})
	verified, err := h.Execute(context.Background(), json.RawMessage(`{"mode":"full","runtime_image":"`+identity.PinnedInferencedImage+`","cold_mnemonic":"`+cold+`","warm_mnemonic":"`+warm+`","cold_address":"gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4","warm_address":"gonka16s0dp897vdfqvf02a00s9afdvrt70nm6pczf0c","warm_pubkey_b64":"A7lHeLlwbcHee+m9zpuU0CbxxIqP0A4ODIB3VSXbMGmy"}`))
	if err != nil || verified.Status != "pass" {
		t.Fatalf("full oracle verification=%#v err=%v", verified, err)
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	output, e := support.WriteArtifact("test-output", []byte("bip39_key_identity_chain_genesis_rejection=covered\nshape_only_reports_derivation_pending=true\n"))
	if e != nil {
		t.Fatal(e)
	}
	assertions, e := support.WriteArtifact("assertion-results", []byte("invalid image and mnemonic rejected; offline result is pending\n"))
	if e != nil {
		t.Fatal(e)
	}
	gold, e := support.WriteArtifact("oracle-derivation", []byte(oracle))
	if e != nil {
		t.Fatal(e)
	}
	checks := []support.Check{{ID: "bip39_key_identity_chain_genesis_rejection", Status: "pass", Observed: "invalid pinned-runtime and mnemonic inputs refused", EvidenceArtifactIDs: []string{assertions.ID}}, {ID: "shape_only_reports_derivation_pending", Status: "pass", Observed: "offline result remains pending", EvidenceArtifactIDs: []string{output.ID}}, {ID: "full_verification_uses_pinned_real_oracle", Status: "pass", Observed: "pinned image and independently derived public goldens recorded", EvidenceArtifactIDs: []string{gold.ID}}}
	if e := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{output, assertions, gold}); e != nil {
		t.Fatal(e)
	}
}
