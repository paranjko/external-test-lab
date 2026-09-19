package identity

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

// PinnedInferencedImage is the frozen runtime image, including its immutable
// digest. The adapter never discovers or substitutes an image.
const PinnedInferencedImage = "ghcr.io/product-science/inferenced@sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112"

type accountRequest struct {
	Mode         string `json:"mode"`
	RuntimeImage string `json:"runtime_image"`
	ColdMnemonic string `json:"cold_mnemonic"`
	WarmMnemonic string `json:"warm_mnemonic"`
	ColdAddress  string `json:"cold_address"`
	WarmAddress  string `json:"warm_address"`
	WarmPubKey   string `json:"warm_pubkey_b64"`
}

type pinnedMnemonicHandler struct{ deps contracts.Dependencies }

func NewPinnedMnemonicAccountVerificationHandler(deps contracts.Dependencies) contracts.Handler {
	return pinnedMnemonicHandler{deps: deps}
}

func (h pinnedMnemonicHandler) Execute(ctx context.Context, raw json.RawMessage) (contracts.Result, error) {
	var request accountRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		return contracts.Result{}, err
	}
	data := contracts.EmptyResultData()
	pending := "pending"
	data.AccountDerivation = &pending
	result := contracts.Result{SchemaVersion: 1, Command: "validator archive verify", Status: "blocked", Phase: "verification", Code: "account_derivation_pending", Mutation: "none", SignerState: "unknown", Data: data, Resume: json.RawMessage("null"), ExitCode: 0}
	if request.Mode != "full" {
		return result, nil
	}
	if request.RuntimeImage != PinnedInferencedImage {
		return contracts.Result{}, errors.New("full account verification requires the pinned inferenced image")
	}
	if !validMnemonicShape(request.ColdMnemonic) || !validMnemonicShape(request.WarmMnemonic) {
		return contracts.Result{}, errors.New("invalid BIP39 mnemonic shape")
	}
	if h.deps.Runner == nil {
		return contracts.Result{}, errors.New("pinned inferenced runner is unavailable")
	}
	if request.ColdAddress == "" || request.WarmAddress == "" || request.WarmPubKey == "" {
		return contracts.Result{}, errors.New("full account verification requires archive identity expectations")
	}
	// The private home is a fresh 0700 directory below the local instance root.
	// It is bind-mounted only into network-disabled containers and removed before
	// returning. Secrets enter only stdin; they never enter argv or Result.
	parent := h.deps.Root
	if parent == "" {
		return contracts.Result{}, errors.New("local instance root is required for private keyring")
	}
	privateHome, err := os.MkdirTemp(parent, ".gonkactl-inferenced-")
	if err != nil {
		return contracts.Result{}, fmt.Errorf("create private keyring: %w", err)
	}
	defer os.RemoveAll(privateHome)
	if err := os.Chmod(privateHome, 0o700); err != nil {
		return contracts.Result{}, err
	}
	password, err := disposablePassword()
	if err != nil {
		return contracts.Result{}, err
	}
	base := []string{"run", "--rm", "--network", "none", "--user", "1000:1000", "-v", filepath.Clean(privateHome) + ":/keyring", request.RuntimeImage, "inferenced", "--home", "/keyring", "keys"}
	if err := h.run(ctx, base, []string{"add", "cold", "--recover", "--keyring-backend", "file"}, request.ColdMnemonic+"\n"+password+"\n"+password+"\n"); err != nil {
		return contracts.Result{}, err
	}
	cold, err := h.show(ctx, base, "cold", "-a", password)
	if err != nil || cold != request.ColdAddress {
		return contracts.Result{}, errors.New("cold mnemonic does not match archive participant address")
	}
	if err := h.run(ctx, base, []string{"add", "warm", "--recover", "--keyring-backend", "file"}, request.WarmMnemonic+"\n"+password+"\n"+password+"\n"); err != nil {
		return contracts.Result{}, err
	}
	warm, err := h.show(ctx, base, "warm", "-a", password)
	if err != nil || warm != request.WarmAddress {
		return contracts.Result{}, errors.New("warm mnemonic does not match archive warm address")
	}
	pubkey, err := h.show(ctx, base, "warm", "--pubkey", password)
	if err != nil || parsePubKey(pubkey) != request.WarmPubKey {
		return contracts.Result{}, errors.New("warm mnemonic does not match archive warm public key")
	}
	verified := "verified"
	data.AccountDerivation = &verified
	full := true
	result.Status, result.Code, result.Data.FullyVerified = "pass", "account_derivation_verified", &full
	return result, nil
}

func (h pinnedMnemonicHandler) run(ctx context.Context, base, args []string, stdin string) error {
	result, err := h.deps.Runner.Run(ctx, contracts.ProcessSpec{Executable: "docker", Args: append(append([]string{}, base...), args...), Stdin: strings.NewReader(stdin), Timeout: 2 * time.Minute, OutputLimitBytes: 64 << 10})
	if err != nil {
		return err
	}
	if result.ExitCode != 0 || result.Truncated {
		return errors.New("pinned inferenced invocation failed")
	}
	return nil
}

func (h pinnedMnemonicHandler) show(ctx context.Context, base []string, name, flag, password string) (string, error) {
	result, err := h.deps.Runner.Run(ctx, contracts.ProcessSpec{Executable: "docker", Args: append(append([]string{}, base...), "show", name, flag, "--keyring-backend", "file"), Stdin: strings.NewReader(password + "\n"), Timeout: 2 * time.Minute, OutputLimitBytes: 64 << 10})
	if err != nil || result.ExitCode != 0 || result.Truncated {
		return "", errors.New("pinned inferenced readback failed")
	}
	return strings.TrimSpace(string(result.Stdout)), nil
}

func parsePubKey(value string) string {
	var key struct {
		Key string `json:"key"`
	}
	if json.Unmarshal([]byte(value), &key) != nil {
		return ""
	}
	return key.Key
}

func disposablePassword() (string, error) {
	bytes := make([]byte, 24)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func validMnemonicShape(value string) bool {
	words := strings.Fields(value)
	if len(words) != 24 {
		return false
	}
	for _, word := range words {
		for _, r := range word {
			if r < 'a' || r > 'z' {
				return false
			}
		}
	}
	return true
}
