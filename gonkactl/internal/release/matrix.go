package release

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewCandidateDefinitionsAndHiddenSourceHelpersHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		Definitions                            []Definition `json:"definitions"`
		SourceRef, Profile, Layer, CheckoutSHA string
	}
	if json.Unmarshal(input, &r) != nil {
		return fail("invalid_candidate_input", 2), nil
	}
	d, e := Select(r.Definitions, r.SourceRef, r.Profile, r.Layer)
	if e != nil || VerifySource(d, r.CheckoutSHA) != nil {
		return fail("candidate_source_unverified", 4), nil
	}
	data := contracts.EmptyResultData()
	data.Matrix = json.RawMessage(`{"profile":"` + d.Profile + `","layer":"` + d.Layer + `","definition_sha256":"` + d.SHA256 + `"}`)
	return contracts.Result{SchemaVersion: 1, Command: "release candidate prepare", Status: "planned", Phase: "prepare", Code: "candidate_definition_verified", Mutation: "none", SignerState: "unknown", Data: data, ExitCode: 0}, nil
}
func fail(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "release candidate prepare", Status: "failed", Phase: "prepare", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Candidate definition was refused.", Retryable: false}, ExitCode: e}
}
