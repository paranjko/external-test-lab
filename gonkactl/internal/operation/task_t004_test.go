package operation

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/config"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type acceptingValidator struct{}

func (acceptingValidator) Validate(string, json.RawMessage) error { return nil }

func TestTask_T004(t *testing.T) {
	root := t.TempDir()
	store, err := NewStore(root, acceptingValidator{}, []string{"state/active.json", "state/value.json", "state/link.json"}, filepath.Join(root, "host-locks"))
	if err != nil {
		t.Fatal(err)
	}
	first := contracts.Document{SchemaRef: "runtime.schema.json#/$defs/active_record", Bytes: []byte(`{"version":1}`)}
	if err := store.CAS(context.Background(), "state/value.json", nil, first); err != nil {
		t.Fatal(err)
	}
	stored, err := store.Read(context.Background(), "state/value.json")
	if err != nil || string(stored.Bytes) != string(first.Bytes) {
		t.Fatalf("read = %#v, %v", stored, err)
	}
	if err := store.CAS(context.Background(), "state/value.json", nil, first); !errors.Is(err, ErrConflict) {
		t.Fatalf("create-only CAS = %v", err)
	}
	if err := store.CAS(context.Background(), "state/value.json", &stored.SHA256, contracts.Document{SchemaRef: first.SchemaRef, Bytes: []byte(`{"version":2}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.CAS(context.Background(), "../escape", nil, first); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("traversal = %v", err)
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(root, "state", "link.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Read(context.Background(), "state/link.json"); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("symlink = %v", err)
	}

	firstLock, err := store.Lock(context.Background(), "instance")
	if err != nil {
		t.Fatal(err)
	}
	locked, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.Lock(locked, "instance"); !errors.Is(err, context.Canceled) {
		t.Fatalf("contended lock = %v", err)
	}
	if err := firstLock.Close(); err != nil {
		t.Fatal(err)
	}

	active := ActiveRecord{DataGenerationID: "data-a", DataGenerationSHA256: repeat("a", 64), DeploymentGenerationID: "deploy-a", DeploymentSHA256: repeat("b", 64), RunID: "run-a"}
	if err := CommitActive(context.Background(), store, nil, active); err != nil {
		t.Fatal(err)
	}
	got, current, err := ReadActive(context.Background(), store)
	if err != nil || got != active || current == "" {
		t.Fatalf("active = %#v %q %v", got, current, err)
	}
	if err := CommitActive(context.Background(), store, nil, active); !errors.Is(err, ErrConflict) {
		t.Fatalf("active create-only = %v", err)
	}

	validator, err := config.NewValidator()
	if err != nil {
		t.Fatal(err)
	}
	journalKey := "runs/20260912T120000Z-deadbeef/journal.json"
	realStore, err := NewStore(t.TempDir(), validator, []string{journalKey}, filepath.Join(root, "real-host-locks"))
	if err != nil {
		t.Fatal(err)
	}
	var frozenStore contracts.Store = realStore
	journal, err := NewJournal(frozenStore, validator, journalKey)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Create(context.Background(), json.RawMessage(`{}`)); err == nil {
		t.Fatal("invalid frozen journal accepted")
	}
	if err := journal.Create(context.Background(), journalFixture()); err != nil {
		t.Fatalf("create frozen journal: %v", err)
	}
	_, digestBefore, err := journal.Read(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	intent := transactionIntentFixture("tx-prepare-1")
	if err := journal.RecordPreparedIntent(context.Background(), &digestBefore, intent); err != nil {
		t.Fatalf("record prepared intent: %v", err)
	}
	if foundIntent, found, err := journal.FindIntent(context.Background(), "tx-prepare-1"); err != nil || !found || string(foundIntent) != string(intent) {
		t.Fatalf("readback intent=%s found=%v err=%v", foundIntent, found, err)
	}
	if err := journal.RecordPreparedIntent(context.Background(), &digestBefore, intent); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale pre-broadcast write = %v", err)
	}
	_, digestAfter, err := journal.Read(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordPreparedIntent(context.Background(), &digestAfter, transactionIntentFixture("tx-prepare-1")); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate intent = %v", err)
	}
	invalidIntent := transactionIntentFixture("tx-prepare-2")
	var invalid map[string]any
	if err := json.Unmarshal(invalidIntent, &invalid); err != nil {
		t.Fatal(err)
	}
	invalid["state"] = "broadcast"
	if err := journal.RecordPreparedIntent(context.Background(), &digestAfter, mustJSON(invalid)); err == nil {
		t.Fatal("non-prepared intent accepted")
	}
	if _, found, err := journal.FindIntent(context.Background(), "tx-prepare-2"); err != nil || found {
		t.Fatalf("invalid intent persisted: found=%v err=%v", found, err)
	}
}

func journalFixture() json.RawMessage {
	hash := func(value string) string { return repeat(value, 64) }
	return mustJSON(map[string]any{
		"schema_version": 1, "run_id": "20260912T120000Z-deadbeef", "parent_run_id": nil,
		"operation": "join_new", "command": "host join", "created_at": "2026-09-12T12:00:00Z", "updated_at": "2026-09-12T12:00:00Z",
		"binding": map[string]any{
			"home": "/var/lib/gonkactl", "instance_id": "123e4567-e89b-42d3-a456-426614174000", "machine_id": repeat("a", 32), "lineage": nil, "identity": nil,
			"binary_pin":    map[string]any{"version": "0.2.15", "path": "/usr/local/lib/gonkactl/0.2.15/gonkactl", "sha256": hash("b"), "guard_abi": 1, "service_abi": 1, "assets_sha256": hash("c")},
			"inputs_sha256": hash("d"), "archive_sha256": nil, "runtime_profile_sha256": nil, "network_plan_sha256": nil, "initial_active_record_sha256": nil,
		},
		"status": "planned", "phase": "prepare", "join_state": nil, "initial_classification": "fresh", "signer_may_be_on": false, "current_generation": nil,
		"completed_phases":    []any{},
		"entries":             []any{map[string]any{"seq": "1", "timestamp": "2026-09-12T12:00:00Z", "phase": "prepare", "event": "transaction_intent_prepared", "state": "intent", "inputs_sha256": hash("d"), "receipt_sha256": nil, "generation": nil, "code": "transaction_intent_prepared"}},
		"transaction_intents": []any{}, "evidence": []any{}, "snapshots": []any{}, "initial_trust_evidence": nil, "post_sync_evidence": nil, "isolation_h0": nil, "isolation_h1": nil,
		"activation_floor": nil, "lifecycle_started_at": nil, "lifecycle_deadline_at": nil, "next_action": nil, "terminal_result_sha256": nil,
	})
}

func transactionIntentFixture(id string) json.RawMessage {
	hash := func(value string) string { return repeat(value, 64) }
	return mustJSON(map[string]any{
		"id": id, "action": "participant_register",
		"lineage":         map[string]any{"chain_id": "gonka-devnet", "genesis_raw_sha256": hash("e"), "genesis_identity_sha256": hash("f")},
		"account_address": "gonka13wm6a6sea08j7auq63wy42l8fsrwd9jks89lt4", "account_sequence": "1", "unsigned_bytes_sha256": hash("1"),
		"signed_bytes_sha256": nil, "tx_hash": nil, "state": "prepared", "prepared_at": "2026-09-12T12:00:00Z", "last_readback_at": nil, "committed_height": nil, "effect_receipt_sha256": nil,
	})
}

func mustJSON(value any) json.RawMessage {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func FuzzOwnedPaths(f *testing.F) {
	for _, seed := range []string{"../x", "/tmp/x", "state/../x", "state/value.json", "", `state\\x`} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, key string) {
		root := t.TempDir()
		store, err := NewStore(root, acceptingValidator{}, []string{"state/value.json"}, filepath.Join(root, "host"))
		if err != nil {
			t.Fatal(err)
		}
		err = store.CAS(context.Background(), key, nil, contracts.Document{SchemaRef: "runtime.schema.json#/$defs/active_record", Bytes: []byte(`{}`)})
		if key != "state/value.json" && !errors.Is(err, ErrUnsafePath) {
			t.Fatalf("unowned key %q produced %v", key, err)
		}
	})
}

func repeat(value string, count int) string {
	output := ""
	for range count {
		output += value
	}
	return output
}
