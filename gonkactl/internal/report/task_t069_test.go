package report

import "testing"

func TestTask_T069(t *testing.T) {
	p := Publication{Repository: "o/r", Author: "owner", IssueState: "open", Marker: "m", BodyHash: "h", Explicit: true}
	if p.Validate() != nil || !p.Verified("owner", "m", "h") {
		t.Fatal("valid publication refused")
	}
	p.IssueState = "closed"
	if p.Validate() == nil {
		t.Fatal("closed issue accepted")
	}
}
