package identity

import "testing"

func TestTask_T019(t *testing.T) {
	keys, err := GenerateFreshStableKeys()
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateFreshStableKeys(keys); err != nil {
		t.Fatal(err)
	}
	if got, err := RegisterFresh(nil, keys); err != nil || got.NodeID != keys.NodeID {
		t.Fatalf("register=%#v %v", got, err)
	}
	other, err := GenerateFreshStableKeys()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RegisterFresh(&keys, other); err == nil {
		t.Fatal("regeneration conflict accepted")
	}
}
