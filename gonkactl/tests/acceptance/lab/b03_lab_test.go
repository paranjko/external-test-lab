package lab

import "testing"

// This executor is deliberately present but never converts portable code
// evidence into lab evidence. A scoped lab invocation is owner-controlled.
func TestAcceptance_B03_Lab(t *testing.T) {
	if testing.Short() {
		t.Skip("docker lab is not run by portable code gates")
	}
	t.Skip("requires separately authorized disposable docker-lab mutation")
}
