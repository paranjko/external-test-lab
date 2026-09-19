package report

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func DraftHash(text string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(Sanitize(text)))) }

type handler struct{ deps contracts.Dependencies }

func NewSanitizedLocalGithubReportDraftHandler(deps contracts.Dependencies) contracts.Handler {
	return handler{deps}
}
func (h handler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var r struct {
		Diagnostics []Diagnostic `json:"diagnostics"`
		Text        string       `json:"text"`
	}
	if json.Unmarshal(input, &r) != nil {
		return fail("invalid_report_draft", 2), nil
	}
	d := LatestOperationalFailure(r.Diagnostics)
	data := contracts.EmptyResultData()
	data.Profile = json.RawMessage(`{"published":false,"draft_sha256":"` + DraftHash(d.Code+":"+r.Text) + `"}`)
	return contracts.Result{SchemaVersion: 1, Command: "report github draft", Status: "planned", Phase: "draft", Code: "not_published", Mutation: "none", SignerState: "unknown", Data: data, ExitCode: 0}, nil
}
func fail(c string, e int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "report github draft", Status: "failed", Phase: "parse", Code: c, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: c, Message: "Report draft input was refused.", Retryable: false}, ExitCode: e}
}
