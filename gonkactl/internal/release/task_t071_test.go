package release

import "testing"

func TestTask_T071(t *testing.T) {
	i := WorkflowIntent{CandidateSHA: "a", Workflow: "candidate", DryRun: true}
	if i.Validate() != nil {
		t.Fatal("dry run refused")
	}
	if i.RetryAllowed(false) {
		t.Fatal("retry without readback")
	}
}
