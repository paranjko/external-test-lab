package release

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type profileHandler struct{ deps contracts.Dependencies }

func NewCandidateProfileMaterializationAndVerificationHandler(deps contracts.Dependencies) contracts.Handler {
	return profileHandler{deps}
}
func (h profileHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var m BuildManifest
	if json.Unmarshal(input, &m) != nil || m.Validate() != nil {
		return profileFail("candidate_profile_unverified", 4), nil
	}
	p, e := RenderProfile(m)
	if e != nil {
		return profileFail("candidate_profile_unverified", 4), nil
	}
	d := contracts.EmptyResultData()
	d.Profile = p
	return contracts.Result{SchemaVersion: 1, Command: "release candidate profile", Status: "planned", Phase: "verify", Code: "candidate_profile_verified", Mutation: "none", SignerState: "unknown", Data: d, ExitCode: 0}, nil
}
func profileFail(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "release candidate profile", Status: "blocked", Phase: "verify", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Candidate profile is not fully bound.", Retryable: false}, ExitCode: e}
}
