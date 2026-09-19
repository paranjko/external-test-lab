package operation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

const JournalSchema = "runtime.schema.json#/$defs/journal"
const TransactionIntentSchema = "runtime.schema.json#/$defs/transaction_intent"

// Journal persists the one schema-defined run journal. Transaction intents are
// embedded in that CAS-protected document: an ambiguous write needs a durable,
// validated pre-broadcast intent before readback or retry.
type Journal struct {
	store     contracts.Store
	validator contracts.Validator
	key       string
}

func NewJournal(store contracts.Store, validator contracts.Validator, key string) (*Journal, error) {
	if store == nil || validator == nil || !safeKey(key) {
		return nil, ErrUnsafePath
	}
	return &Journal{store: store, validator: validator, key: key}, nil
}

// Create persists an already complete frozen journal object exactly once.
func (j *Journal) Create(ctx context.Context, raw json.RawMessage) error {
	if j == nil {
		return ErrUnsafePath
	}
	if err := j.validator.Validate(JournalSchema, raw); err != nil {
		return fmt.Errorf("invalid journal: %w", err)
	}
	return j.store.CAS(ctx, j.key, nil, contracts.Document{SchemaRef: JournalSchema, Bytes: raw, SHA256: digest(raw)})
}

func (j *Journal) Read(ctx context.Context) (json.RawMessage, string, error) {
	if j == nil {
		return nil, "", ErrUnsafePath
	}
	doc, err := j.store.Read(ctx, j.key)
	if err != nil {
		return nil, "", err
	}
	return append(json.RawMessage(nil), doc.Bytes...), doc.SHA256, nil
}

// RecordPreparedIntent validates and durably appends a prepared transaction
// intent before broadcast. expectedSHA256 binds this mutation to the exact
// journal read immediately before preparation.
func (j *Journal) RecordPreparedIntent(ctx context.Context, expectedSHA256 *string, raw json.RawMessage) error {
	if j == nil || expectedSHA256 == nil {
		return ErrUnsafePath
	}
	if err := j.validator.Validate(TransactionIntentSchema, raw); err != nil {
		return fmt.Errorf("invalid transaction intent: %w", err)
	}
	var intent struct {
		ID              string          `json:"id"`
		State           string          `json:"state"`
		SignedBytesHash json.RawMessage `json:"signed_bytes_sha256"`
		TxHash          json.RawMessage `json:"tx_hash"`
	}
	if err := json.Unmarshal(raw, &intent); err != nil || intent.ID == "" || intent.State != "prepared" || string(intent.SignedBytesHash) != "null" || string(intent.TxHash) != "null" {
		return errors.New("pre-broadcast intent must be unsigned, unhashed, and prepared")
	}
	doc, err := j.store.Read(ctx, j.key)
	if err != nil {
		return err
	}
	if doc.SHA256 != *expectedSHA256 {
		return ErrConflict
	}
	var journal map[string]json.RawMessage
	if err := json.Unmarshal(doc.Bytes, &journal); err != nil {
		return fmt.Errorf("decode journal: %w", err)
	}
	var intents []json.RawMessage
	if err := json.Unmarshal(journal["transaction_intents"], &intents); err != nil {
		return fmt.Errorf("decode transaction intents: %w", err)
	}
	for _, existing := range intents {
		var current struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(existing, &current) == nil && current.ID == intent.ID {
			return ErrConflict
		}
	}
	intents = append(intents, append(json.RawMessage(nil), raw...))
	encodedIntents, err := json.Marshal(intents)
	if err != nil {
		return err
	}
	journal["transaction_intents"] = encodedIntents
	updated, err := json.Marshal(time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return err
	}
	journal["updated_at"] = updated
	next, err := json.Marshal(journal)
	if err != nil {
		return err
	}
	if err := j.validator.Validate(JournalSchema, next); err != nil {
		return fmt.Errorf("invalid journal: %w", err)
	}
	return j.store.CAS(ctx, j.key, expectedSHA256, contracts.Document{SchemaRef: JournalSchema, Bytes: next, SHA256: digest(next)})
}

// FindIntent is read-only reconciliation evidence. It never authorizes retry.
func (j *Journal) FindIntent(ctx context.Context, id string) (json.RawMessage, bool, error) {
	if j == nil || id == "" {
		return nil, false, ErrUnsafePath
	}
	raw, _, err := j.Read(ctx)
	if err != nil {
		return nil, false, err
	}
	var journal struct {
		Intents []json.RawMessage `json:"transaction_intents"`
	}
	if err := json.Unmarshal(raw, &journal); err != nil {
		return nil, false, fmt.Errorf("decode journal: %w", err)
	}
	for _, intent := range journal.Intents {
		var current struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(intent, &current) == nil && current.ID == id {
			return append(json.RawMessage(nil), intent...), true, nil
		}
	}
	return nil, false, nil
}
