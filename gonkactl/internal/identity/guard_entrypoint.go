package identity

import (
	"context"
	"encoding/json"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type guardHandler struct{ deps contracts.Dependencies }

func NewPersistentSignerGuardAndEntrypointHandler(deps contracts.Dependencies) contracts.Handler {
	return guardHandler{deps: deps}
}

// Execute is the fixed local entrypoint for every managed TMKMS start. It does
// not call Docker or Core RPC: a normal reboot must be decided from durable,
// already-qualified state before the signer can unblock Core.
func (h guardHandler) Execute(ctx context.Context, _ json.RawMessage) (contracts.Result, error) {
	guard, _, err := ReadGuard(ctx, h.deps.Store)
	if err != nil || guard.AllowsStart() != nil {
		return guardResult("signer_guard_refused", "blocked", 3), nil
	}
	data := contracts.EmptyResultData()
	data.RequiresQualification = false
	return contracts.Result{SchemaVersion: 1, Command: "internal signer-exec", Status: "planned", Phase: "guard", Code: "signer_guard_authorized", Mutation: "none", SignerState: "authorized", Data: data, ExitCode: 0}, nil
}

func guardResult(code, status string, exit int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "internal signer-exec", Status: status, Phase: "guard", Code: code, Mutation: "none", SignerState: "blocked", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Managed signer start was refused by the durable guard.", Retryable: false}, ExitCode: exit}
}
