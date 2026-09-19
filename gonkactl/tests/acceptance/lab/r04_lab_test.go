package lab

import (
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_R04_Lab(t *testing.T) {
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		t.Skip("requires separately authorized disposable VM reboot executor")
	}
	output, err := support.WriteArtifact("test-output", []byte("disposable_vm_reboot=not_authorized\n"))
	if err != nil {
		t.Fatal(err)
	}
	trace, err := support.WriteArtifact("reboot-and-guard-trace", []byte("no disposable VM authority or fixture was supplied\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{{ID: "lab_environment", Status: "not_run", Observed: "disposable VM authorization and environment are unavailable", EvidenceArtifactIDs: []string{output.ID, trace.ID}}}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "not_run", "environment_unavailable", checks, []support.Artifact{output, trace}); err != nil {
		t.Fatal(err)
	}
	t.Skip("disposable VM reboot executor is not implemented; receipt records not_run")
}
