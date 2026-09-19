package lab

import "testing"

// The wrapper supplies a qualified disposable Ubuntu VM manifest before this
// test may write a receipt. Local package tests never represent lab evidence.
func TestAcceptance_C04_Lab(t *testing.T) {
	if testing.Short() {
		t.Skip("requires qualified disposable Ubuntu VM")
	}
	t.Skip("disposable Ubuntu VM executor is not implemented")
}
