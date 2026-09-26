package lab

import "testing"

// The gate wrapper returns not_run before this test when no separately
// authorized disposable lab environment is supplied. It never treats code
// evidence as a lab transaction result.
func TestAcceptance_J05_Lab(t *testing.T) {
	if testing.Short() {
		t.Skip("lab transaction tests are not run by portable code gates")
	}
	// Real scoped participant/funding/grant mutation is intentionally absent
	// without the required lab manifest and authorization.
	t.Skip("lab transaction executor is not implemented")
}
