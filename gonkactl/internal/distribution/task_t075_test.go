package distribution

import "testing"

func TestTask_T075(t *testing.T) {
	a := Asset{"amd64", "https://example/a", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1}
	if a.Validate() != nil {
		t.Fatal("valid asset refused")
	}
	a.URL = "http://x"
	if a.Validate() == nil {
		t.Fatal("insecure URL accepted")
	}
}
