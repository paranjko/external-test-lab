package platform

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

func TestTask_T008(t *testing.T) {
	if err := RequireRoot(0); err != nil {
		t.Fatal(err)
	}
	if err := RequireRoot(1000); err == nil {
		t.Fatal("non-root must be refused without SUDO_USER inference")
	}
	if !SupportedHost("24.04", "amd64") || SupportedHost("24.04", "arm64") || SupportedHost("debian", "amd64") {
		t.Fatal("unsupported host matrix")
	}
	role, err := ResolveRole(RoleAuto, false)
	if err != nil || role != RoleNetworkOnly {
		t.Fatalf("auto role = %q, %v", role, err)
	}
	plan, err := NewFirewallPlan(RoleMLOnly, true)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Allows(5000) || !plan.Allows(18080) || plan.Allows(8081) || plan.Validate() != nil {
		t.Fatalf("unexpected plan: %#v", plan)
	}
	handler := NewRoleAwarePlatformPreparationHandler(contracts.Dependencies{})
	result, err := handler.Execute(context.Background(), json.RawMessage(`{"role":"auto","gpu_supported":false}`))
	if err != nil || result.Status != "planned" || result.Mutation != "none" {
		t.Fatalf("handler result = %#v, %v", result, err)
	}
}
