package artifact

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type resolverHandler struct{ deps contracts.Dependencies }

func NewObservedRuntimeArtifactResolutionHandler(deps contracts.Dependencies) contracts.Handler {
	return resolverHandler{deps}
}
func (h resolverHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		CoreVersion, CoreCommit, DAPIVersion, DAPICommit string
		Core, DAPI                                       ReleaseMetadata `json:"-"`
		Images                                           []string        `json:"images"`
	}
	if json.Unmarshal(input, &r) != nil {
		return artifactResult("invalid_runtime_resolution_input", 2), nil
	}
	if _, e := ResolveRelease(r.Core, r.CoreVersion, "inferenced-linux-amd64.zip"); e != nil {
		return artifactResult("artifact_unavailable", 4), nil
	}
	if _, e := ResolveRelease(r.DAPI, r.DAPIVersion, "decentralized-api-amd64.zip"); e != nil {
		return artifactResult("artifact_unavailable", 4), nil
	}
	for _, i := range r.Images {
		if ImmutableImage(i) != nil {
			return artifactResult("unsupported_host_template", 3), nil
		}
	}
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: "planned", Phase: "resolve", Code: "runtime_artifacts_resolved", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func artifactResult(code string, exit int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: "failed", Phase: "resolve", Code: code, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Observed runtime artifacts are unavailable or invalid.", Retryable: true}, ExitCode: exit}
}
