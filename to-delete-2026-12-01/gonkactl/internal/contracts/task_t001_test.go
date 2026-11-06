package contracts

import "testing"

func TestTask_T001(t *testing.T) {
	data := EmptyResultData()
	if data.Receipts == nil || data.Outputs == nil || data.PendingActions == nil {
		t.Fatal("empty result data must preserve empty arrays rather than null")
	}
	if len(data.Receipts) != 0 || len(data.Outputs) != 0 || len(data.PendingActions) != 0 {
		t.Fatal("empty result data must not invent domain output")
	}
	if ServiceABI != 1 {
		t.Fatalf("ServiceABI = %d, want 1", ServiceABI)
	}
}
