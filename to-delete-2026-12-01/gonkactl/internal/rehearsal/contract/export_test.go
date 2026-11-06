package contract

import "testing"

func TestExternalExportIsReadOnlyInputRole(t *testing.T) {
	b := binding()
	b.Paths["export"] = "/tmp/frozen-original"
	b.Paths["peer_workspace"] = "/tmp/independent-peer"
	if err := ValidateBinding(b); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{"source", "control", "fork-a", "fork-b", "evidence"} {
		candidate := binding()
		candidate.Paths[role] = "/tmp/outside-run"
		if ValidateBinding(candidate) == nil {
			t.Fatalf("external writable role %s accepted", role)
		}
	}
	for _, path := range []string{"/", "relative", "/tmp/../outside", b.Workspace} {
		b.Paths["export"] = path
		if ValidateBinding(b) == nil {
			t.Fatalf("unsafe export %q accepted", path)
		}
	}
	b.Paths["export"] = "/tmp/frozen-original"
	for _, path := range []string{"/", "relative", "/tmp/../outside", b.Workspace} {
		b.Paths["peer_workspace"] = path
		if ValidateBinding(b) == nil {
			t.Fatalf("unsafe peer reference %q accepted", path)
		}
	}
}
