package join

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/operation"
)

type transactionHandler struct{ deps contracts.Dependencies }

func NewReadbackSafeParticipantTransactionsHandler(deps contracts.Dependencies) contracts.Handler {
	return transactionHandler{deps: deps}
}

// Execute accepts only a locally supplied, already-prepared transaction intent.
// It deliberately does not broadcast: network endpoints and signing authority
// are provided only by the later command wiring and are never inferred here.
func (h transactionHandler) Execute(ctx context.Context, raw json.RawMessage) (contracts.Result, error) {
	var input struct {
		JournalKey string          `json:"journal_key"`
		Intent     json.RawMessage `json:"intent"`
	}
	if json.Unmarshal(raw, &input) != nil || input.JournalKey == "" || len(input.Intent) == 0 || h.deps.Store == nil || h.deps.Validator == nil || h.deps.Validator.Validate(operation.TransactionIntentSchema, input.Intent) != nil {
		return transactionResult("transaction_intent_refused", "failed", 2), nil
	}
	var state struct {
		State string `json:"state"`
	}
	if json.Unmarshal(input.Intent, &state) != nil || state.State != "prepared" {
		return transactionResult("transaction_intent_not_prepared", "blocked", 3), nil
	}
	journal, err := operation.NewJournal(h.deps.Store, h.deps.Validator, input.JournalKey)
	if err != nil {
		return transactionResult("transaction_journal_refused", "failed", 2), nil
	}
	_, current, err := journal.Read(ctx)
	if err != nil {
		return transactionResult("transaction_journal_unavailable", "blocked", 3), nil
	}
	if err := journal.RecordPreparedIntent(ctx, &current, input.Intent); err != nil {
		return transactionResult("transaction_intent_not_durable", "blocked", 3), nil
	}
	return transactionResult("transaction_readback_required", "planned", 0), nil
}

func transactionResult(code, status string, exit int) contracts.Result {
	data := contracts.EmptyResultData()
	data.RequiresQualification = true
	return contracts.Result{SchemaVersion: 1, Command: "host join", Status: status, Phase: "reconcile", Code: code, Mutation: "none", SignerState: "unknown", Data: data, ExitCode: exit}
}

var ErrRunnerUnavailable = errors.New("transaction runner is unavailable")
