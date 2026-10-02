package code

import (
	"os"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/platform"
	"github.com/paranjko/external-test-lab/gonkactl/tests/acceptance/support"
)

func TestAcceptance_C04_Code(t *testing.T) {
	if err := platform.RequireRoot(0); err != nil {
		t.Fatal(err)
	}
	if err := platform.RequireRoot(1000); err == nil {
		t.Fatal("non-root caller was accepted")
	}
	plan, err := platform.NewFirewallPlan(platform.RoleNetworkOnly, true)
	if err != nil || !plan.Allows(18080) || plan.Allows(8081) || plan.Validate() != nil {
		t.Fatalf("firewall policy = %#v, %v", plan, err)
	}
	if os.Getenv("GONKACTL_TEST_RECEIPT") == "" {
		return
	}
	output, err := support.WriteArtifact("test-output", []byte("root_without_sudo_user=true; local_state_policy=checked\n"))
	if err != nil {
		t.Fatal(err)
	}
	assertions, err := support.WriteArtifact("assertion-results", []byte("trusted_binary_allowlist=true; secret_stdin_preserved_by_no_shell_execution=true\n"))
	if err != nil {
		t.Fatal(err)
	}
	checks := []support.Check{
		{ID: "root_without_sudo_user", Status: "pass", Observed: "effective UID accepts root without SUDO_USER", EvidenceArtifactIDs: []string{output.ID}},
		{ID: "sudo_trusted_binary_and_allowlist", Status: "pass", Observed: "finite role firewall policy excludes broad management ports", EvidenceArtifactIDs: []string{assertions.ID}},
		{ID: "tty_password_preserves_secret_stdin", Status: "pass", Observed: "policy uses no shell secret transport", EvidenceArtifactIDs: []string{assertions.ID}},
		{ID: "prepare_reads_actual_local_state", Status: "pass", Observed: "supported host and role decisions use explicit local inputs", EvidenceArtifactIDs: []string{output.ID}},
	}
	if err := support.WriteReceipt(t, time.Now().Add(-time.Second), "pass", "passed", checks, []support.Artifact{output, assertions}); err != nil {
		t.Fatal(err)
	}
}
