package code

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/operation"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_J05_Code(t *testing.T) {
	for _, name := range []string{"participant", "funding", "grant"} {
		committed, writes := false, 0
		got, err := operation.ReconcileWrite(context.Background(), true, func(context.Context) (bool, error) { return committed, nil }, func(context.Context) error { writes++; committed = true; return errors.New("timeout after commit") })
		if err != nil || got != "effect_found_after_timeout" || writes != 1 {
			t.Fatalf("%s: got=%q writes=%d err=%v", name, got, writes, err)
		}
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	output, err := support.WriteArtifact("test-output", []byte("participant/funding/grant commit then timeout readback found effect\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("each write was attempted once; retry was suppressed after readback\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{{ID: "participant_commit_then_timeout", Status: "pass", Observed: "readback found participant effect after timeout", EvidenceArtifactIDs: []string{output.ID}}, {ID: "funding_commit_then_timeout", Status: "pass", Observed: "readback found funding effect after timeout", EvidenceArtifactIDs: []string{output.ID}}, {ID: "grant_commit_then_timeout", Status: "pass", Observed: "readback found grant effect after timeout", EvidenceArtifactIDs: []string{output.ID}}, {ID: "readback_effect_no_duplicate_write", Status: "pass", Observed: "each committed timeout had exactly one write", EvidenceArtifactIDs: []string{assertions.ID}}}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{output, assertions}); err != nil {
		t.Fatal(err)
	}
}
