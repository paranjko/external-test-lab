package release

import "testing"

func TestTask_T072(t *testing.T) {
	m := BuildManifest{"p", "d", "s", "runtime", "a"}
	if _, e := RenderProfile(m); e != nil {
		t.Fatal(e)
	}
	m.RuntimeID = ""
	if m.Validate() == nil {
		t.Fatal("identity missing")
	}
}
