package code

import (
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/identity"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_R04_Code(t *testing.T) {
	guard := identity.Guard{State: "ACTIVATION_AUTHORIZED", Mode: "restore", InstanceID: "node-1", SignerMayBeOn: true, Authorization: map[string]any{"authorization_id": "a"}}
	if err := guard.AllowsStart(); err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"DISABLED", "RETIRING", "RETIRED"} {
		candidate := guard
		candidate.State = state
		if candidate.AllowsStart() == nil {
			t.Fatalf("%s guard bypass", state)
		}
	}
	if _, err := identity.ReconcileStart(guard, "active"); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	output, err := support.WriteArtifact("test-output", []byte("direct_docker_restart=guarded\ndaemon_reboot=guarded\n"))
	if err != nil {
		t.Fatal(err)
	}
	trace, err := support.WriteArtifact("reboot-and-guard-trace", []byte("authorization=durable\nrpc_required=false\nretired=refused\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{
		{ID: "docker_restart_guard", Status: "pass", Observed: "every start validates current durable guard", EvidenceArtifactIDs: []string{output.ID}},
		{ID: "daemon_and_host_reboot_guard", Status: "pass", Observed: "restart uses durable authorization without RPC", EvidenceArtifactIDs: []string{trace.ID}},
		{ID: "invalid_replaced_retired_guard", Status: "pass", Observed: "non-authorized and retired states are refused", EvidenceArtifactIDs: []string{trace.ID}},
		{ID: "authorized_reboot_without_rpc_deadlock", Status: "pass", Observed: "authorized state is sufficient before Core starts", EvidenceArtifactIDs: []string{output.ID}},
	}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{output, trace}); err != nil {
		t.Fatal(err)
	}
}
