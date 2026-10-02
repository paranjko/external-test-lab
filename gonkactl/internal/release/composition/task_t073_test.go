package composition

import "testing"

func TestTask_T073(t *testing.T) {
	d := Create("core", "dev", "gov")
	if Verify(d) != nil {
		t.Fatal("valid descriptor refused")
	}
	d.SelfContained = false
	if Verify(d) == nil {
		t.Fatal("workspace-free invalid descriptor accepted")
	}
}
