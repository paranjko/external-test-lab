package operation

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

// ActiveRecord is the only mutable generation pointer. Data and deployment
// generations are committed as one document, so readers cannot combine them
// across operations.
type ActiveRecord struct {
	DataGenerationID       string `json:"data_generation_id"`
	DataGenerationSHA256   string `json:"data_generation_sha256"`
	DeploymentGenerationID string `json:"deployment_generation_id"`
	DeploymentSHA256       string `json:"deployment_sha256"`
	RunID                  string `json:"run_id"`
}

func (r ActiveRecord) valid() bool {
	return r.DataGenerationID != "" && r.DeploymentGenerationID != "" && r.RunID != "" && len(r.DataGenerationSHA256) == 64 && len(r.DeploymentSHA256) == 64
}

func CommitActive(ctx context.Context, store *Store, expected *string, record ActiveRecord) error {
	if store == nil || !record.valid() {
		return errors.New("invalid active generation pair")
	}
	encoded, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return store.CAS(ctx, "state/active.json", expected, contracts.Document{SchemaRef: "runtime.schema.json#/$defs/active_record", Bytes: encoded, SHA256: digest(encoded)})
}

func ReadActive(ctx context.Context, store *Store) (ActiveRecord, string, error) {
	if store == nil {
		return ActiveRecord{}, "", errors.New("nil store")
	}
	document, err := store.Read(ctx, "state/active.json")
	if err != nil {
		return ActiveRecord{}, "", err
	}
	var record ActiveRecord
	if err := json.Unmarshal(document.Bytes, &record); err != nil {
		return ActiveRecord{}, "", err
	}
	if !record.valid() {
		return ActiveRecord{}, "", errors.New("invalid active generation pair")
	}
	return record, document.SHA256, nil
}
