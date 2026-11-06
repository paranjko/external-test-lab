package backup

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/legacyv1"
	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

// VerifyEncoded uses the strict raw-header legacy scanner, not a generic tar
// extraction. It returns the decoded archive identity only after structural
// validation succeeds.
func VerifyEncoded(data []byte) (model.VerifiedArchive, error) {
	archive, err := legacyv1.Scan(bytes.NewReader(data))
	if err != nil {
		return model.VerifiedArchive{}, err
	}
	return legacyv1.Decode(archive)
}

type encodingHandler struct{ deps contracts.Dependencies }

func NewConsistentBackupEncodingHandler(deps contracts.Dependencies) contracts.Handler {
	return encodingHandler{deps: deps}
}
func (h encodingHandler) Execute(_ context.Context, raw json.RawMessage) (contracts.Result, error) {
	var request struct {
		Archive string `json:"archive_b64"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return contracts.Result{}, err
	}
	if request.Archive == "" {
		return contracts.Result{}, errors.New("backup archive input is required")
	}
	data, err := base64.StdEncoding.DecodeString(request.Archive)
	if err != nil {
		return contracts.Result{}, err
	}
	verified, err := VerifyEncoded(data)
	if err != nil {
		return contracts.Result{}, err
	}
	_ = verified
	full := true
	derivation := "pending"
	return contracts.Result{SchemaVersion: 1, Command: "host backup", Status: "pass", Phase: "backup", Code: "archive_verified", Mutation: "none", SignerState: "unknown", Data: contracts.ResultData{Receipts: []json.RawMessage{}, Outputs: []json.RawMessage{}, PendingActions: []json.RawMessage{}, FullyVerified: &full, AccountDerivation: &derivation}, Resume: json.RawMessage("null"), ExitCode: 0}, nil
}
