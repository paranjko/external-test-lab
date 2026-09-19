package site

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewPrebuiltSiteOwnerPublicationHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var m Manifest
	if json.Unmarshal(input, &m) != nil || m.Validate() != nil {
		return fail(), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "ops site apply", Status: "planned", Phase: "stage", Code: "site_publication_staged", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func fail() contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "ops site apply", Status: "failed", Phase: "validate", Code: "site_manifest_invalid", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 2}
}
