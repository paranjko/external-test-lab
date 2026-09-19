package github

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func IntentMarker(target string, body []byte) string {
	return fmt.Sprintf("%x", sha256.Sum256(append([]byte(target), body...)))
}
func Reconcile(ctx context.Context, readback func(context.Context) (bool, error)) error {
	done, e := readback(ctx)
	if e != nil {
		return e
	}
	if !done {
		return fmt.Errorf("mutation outcome unknown; readback required")
	}
	return nil
}

type handler struct{ deps contracts.Dependencies }

func NewGoGithubRequestAndReconciliationAdapterHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	if len(input) == 0 {
		return fail("invalid_github_request", 2), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "report github publish", Status: "planned", Phase: "intent", Code: "github_intent_recorded", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func fail(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "report github publish", Status: "failed", Phase: "parse", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "GitHub request was refused.", Retryable: false}, ExitCode: e}
}
