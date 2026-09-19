package site

import "testing"

func TestTask_T047(t *testing.T) {
	m := Manifest{"r", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
	if m.Validate() != nil || !ProbeExpected(200, []byte("ok")) {
		t.Fatal("valid site rejected")
	}
}
