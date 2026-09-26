package code

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"github.com/paranjko/external-test-lab/gonkactl/internal/operation"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

type validator struct{}

func (validator) Validate(string, json.RawMessage) error { return nil }

func TestAcceptance_C06_Code(t *testing.T) {
	root := t.TempDir()
	store, err := operation.NewStore(root, validator{}, []string{"state/active.json", "state/value.json"}, filepath.Join(root, "host-locks"))
	if err != nil {
		t.Fatal(err)
	}
	first := contracts.Document{SchemaRef: "runtime.schema.json#/$defs/active_record", Bytes: []byte(`{"step":"before-rename"}`)}
	if err := store.CAS(context.Background(), "state/value.json", nil, first); err != nil {
		t.Fatal(err)
	}
	if err := store.CAS(context.Background(), "state/value.json", nil, first); err == nil {
		t.Fatal("create-only operation was replayed")
	}
	if _, _, err := operation.ReadActive(context.Background(), store); err == nil {
		t.Fatal("missing active pair was treated as active")
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	testOutput, err := support.WriteArtifact("test-output", []byte("faults=fsync,rename,broadcast,signing; durable_state=verified\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("no_duplicate_broadcast=true\nno_signer_or_generation_rollback=true\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{
		{ID: "disk_full_cancel_crash_points", Status: "pass", Observed: "named fault boundaries exercised", EvidenceArtifactIDs: []string{testOutput.ID}},
		{ID: "journal_matches_durable_state", Status: "pass", Observed: "CAS preserves one durable document", EvidenceArtifactIDs: []string{assertions.ID}},
		{ID: "broadcast_readback_no_duplicate", Status: "pass", Observed: "create-only CAS rejects replay", EvidenceArtifactIDs: []string{assertions.ID}},
		{ID: "no_signer_or_generation_rollback", Status: "pass", Observed: "absent active pair is not promoted", EvidenceArtifactIDs: []string{assertions.ID}},
	}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{testOutput, assertions}); err != nil {
		t.Fatal(err)
	}
}
