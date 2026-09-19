package identity

import "testing"

func TestTask_T026(t *testing.T) {
	authorized := Guard{State: "ACTIVATION_AUTHORIZED", Mode: "restore", InstanceID: "node-1", SignerMayBeOn: true, Authorization: map[string]any{"id": "a"}}
	if err := authorized.AllowsStart(); err != nil {
		t.Fatal(err)
	}
	if got, err := ReconcileStart(authorized, "active"); err != nil || got.State != "ACTIVE" {
		t.Fatalf("reconcile = %#v, %v", got, err)
	}
	for _, state := range []string{"DISABLED", "RETIRING", "RETIRED"} {
		denied := authorized
		denied.State = state
		if err := denied.AllowsStart(); err == nil {
			t.Fatalf("%s unexpectedly allowed", state)
		}
	}
}
