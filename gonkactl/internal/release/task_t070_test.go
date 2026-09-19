package release

import "testing"

func TestTask_T070(t *testing.T) {
	d := Definition{"p", "src", "layer", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	if _, e := Select([]Definition{d, d}, "src", "", ""); e == nil {
		t.Fatal("ambiguous source accepted")
	}
	if _, e := Select([]Definition{d}, "src", "p", ""); e != nil {
		t.Fatal(e)
	}
}
