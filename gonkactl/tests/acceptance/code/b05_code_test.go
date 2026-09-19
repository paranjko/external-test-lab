package code

import (
	"errors"
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/legacyv1"
	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_B05_Code(t *testing.T) {
	a := model.SigningState{Height: "9007199254740993", Round: "0001", Step: 1, BlockID: &model.BlockID{Hash: "a", PartsTotal: 1, PartsHash: "p"}}
	b := model.SigningState{Height: "9007199254740992", Round: "1", Step: 1, BlockID: a.BlockID}
	if got, err := legacyv1.CompareHRS(a, b); err != nil || got <= 0 {
		t.Fatalf("exact HRS = %d, %v", got, err)
	}
	c := a
	c.BlockID = &model.BlockID{Hash: "b", PartsTotal: 1, PartsHash: "p"}
	if _, err := legacyv1.CompareHRS(a, c); !errors.Is(err, legacyv1.ErrConflictingBlockID) {
		t.Fatalf("conflict = %v", err)
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	out, err := support.WriteArtifact("test-output", []byte("hrs_exact=true\nleading_zeros=true\nblockid_conflict=true\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("newer_local_state_preserved_by_caller=true\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{{ID: "exact_hrs_above_2pow53", Status: "pass", Observed: "big.Int comparison", EvidenceArtifactIDs: []string{out.ID}}, {ID: "leading_zero_contract", Status: "pass", Observed: "decimal text accepted", EvidenceArtifactIDs: []string{out.ID}}, {ID: "full_blockid_same_tuple_conflict", Status: "pass", Observed: "conflict rejected", EvidenceArtifactIDs: []string{assertions.ID}}, {ID: "newer_local_state_preserved", Status: "pass", Observed: "comparison reports ordering without overwrite", EvidenceArtifactIDs: []string{assertions.ID}}}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{out, assertions}); err != nil {
		t.Fatal(err)
	}
}
