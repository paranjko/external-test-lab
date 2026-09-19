package join

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/config"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/operation"
)

func TestTask_T022(t *testing.T) {
	for _, name := range []string{"participant", "funding", "grant"} {
		t.Run(name, func(t *testing.T) {
			committed, writes := false, 0
			outcome, err := operation.ReconcileWrite(context.Background(), true, func(context.Context) (bool, error) { return committed, nil }, func(context.Context) error { writes++; committed = true; return errors.New("response timeout") })
			if err != nil || outcome != "effect_found_after_timeout" || writes != 1 {
				t.Fatalf("%s outcome=%q writes=%d err=%v", name, outcome, writes, err)
			}
		})
	}
	if _, err := operation.ReconcileWrite(context.Background(), false, func(context.Context) (bool, error) { return false, nil }, func(context.Context) error { return nil }); !errors.Is(err, operation.ErrIntentMissing) {
		t.Fatal(err)
	}
	if FaucetOutcome(202, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != "submitted" || FaucetOutcome(409, "") != "readback_required" || len(WarmGrantArgs()) == 0 {
		t.Fatal("frozen adapters")
	}
	validator, err := config.NewValidator()
	if err != nil {
		t.Fatal(err)
	}
	key := "runs/20260912T120000Z-deadbeef/journal.json"
	store, err := operation.NewStore(t.TempDir(), validator, []string{key}, filepath.Join(t.TempDir(), "host-locks"))
	if err != nil {
		t.Fatal(err)
	}
	journal, err := operation.NewJournal(store, validator, key)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Create(context.Background(), joinJournalFixture()); err != nil {
		t.Fatal(err)
	}
	intent := joinIntentFixture("t022-prepared")
	request, err := json.Marshal(map[string]any{"journal_key": key, "intent": json.RawMessage(intent)})
	if err != nil {
		t.Fatal(err)
	}
	result, err := NewReadbackSafeParticipantTransactionsHandler(contracts.Dependencies{Store: store, Validator: validator}).Execute(context.Background(), request)
	if err != nil || result.Status != "planned" || result.Code != "transaction_readback_required" {
		t.Fatalf("durable handler result=%#v err=%v", result, err)
	}
	if got, found, err := journal.FindIntent(context.Background(), "t022-prepared"); err != nil || !found || string(got) != string(intent) {
		t.Fatalf("durable intent got=%s found=%v err=%v", got, found, err)
	}
	refused, err := NewReadbackSafeParticipantTransactionsHandler(contracts.Dependencies{Store: store, Validator: validator}).Execute(context.Background(), []byte(`{"journal_key":"../escape","intent":{}}`))
	if err != nil || refused.Code != "transaction_intent_refused" {
		t.Fatalf("unsafe request result=%#v err=%v", refused, err)
	}
}

func joinJournalFixture() json.RawMessage {
	hash := func(value string) string { return strings.Repeat(value, 64) }
	value := map[string]any{
		"schema_version": 1, "run_id": "20260912T120000Z-deadbeef", "parent_run_id": nil, "operation": "join_new", "command": "host join", "created_at": "2026-09-12T12:00:00Z", "updated_at": "2026-09-12T12:00:00Z",
		"binding": map[string]any{"home": "/var/lib/gonkactl", "instance_id": "123e4567-e89b-42d3-a456-426614174000", "machine_id": strings.Repeat("a", 32), "lineage": nil, "identity": nil, "binary_pin": map[string]any{"version": "0.2.15", "path": "/usr/local/lib/gonkactl/0.2.15/gonkactl", "sha256": hash("b"), "guard_abi": 1, "service_abi": 1, "assets_sha256": hash("c")}, "inputs_sha256": hash("d"), "archive_sha256": nil, "runtime_profile_sha256": nil, "network_plan_sha256": nil, "initial_active_record_sha256": nil},
		"status":  "planned", "phase": "prepare", "join_state": nil, "initial_classification": "fresh", "signer_may_be_on": false, "current_generation": nil, "completed_phases": []any{}, "entries": []any{map[string]any{"seq": "1", "timestamp": "2026-09-12T12:00:00Z", "phase": "prepare", "event": "transaction_intent_prepared", "state": "intent", "inputs_sha256": hash("d"), "receipt_sha256": nil, "generation": nil, "code": "transaction_intent_prepared"}}, "transaction_intents": []any{}, "evidence": []any{}, "snapshots": []any{}, "initial_trust_evidence": nil, "post_sync_evidence": nil, "isolation_h0": nil, "isolation_h1": nil, "activation_floor": nil, "lifecycle_started_at": nil, "lifecycle_deadline_at": nil, "next_action": nil, "terminal_result_sha256": nil,
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func joinIntentFixture(id string) json.RawMessage {
	hash := func(value string) string { return strings.Repeat(value, 64) }
	value := map[string]any{"id": id, "action": "participant_register", "lineage": map[string]any{"chain_id": "gonka-devnet", "genesis_raw_sha256": hash("e"), "genesis_identity_sha256": hash("f")}, "account_address": "gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4", "account_sequence": "1", "unsigned_bytes_sha256": hash("1"), "signed_bytes_sha256": nil, "tx_hash": nil, "state": "prepared", "prepared_at": "2026-09-12T12:00:00Z", "last_readback_at": nil, "committed_height": nil, "effect_receipt_sha256": nil}
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}
