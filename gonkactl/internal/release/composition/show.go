package composition

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type handler struct{ deps contracts.Dependencies }

func NewCompositionCreateVerifyMaterializeShowHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var d Descriptor
	if json.Unmarshal(input, &d) != nil || Verify(d) != nil {
		return fail(), nil
	}
	data := contracts.EmptyResultData()
	data.Profile = Materialize(d)
	return contracts.Result{SchemaVersion: 1, Command: "release composition show", Status: "planned", Phase: "verify", Code: "composition_verified", Mutation: "none", SignerState: "unknown", Data: data, ExitCode: 0}, nil
}
func fail() contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "release composition show", Status: "failed", Phase: "verify", Code: "composition_unverified", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 4}
}
