package bundle

import "testing"

func TestTask_T063(t *testing.T) {
	m := Manifest{ChainID: 11155111, SourceSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", LockSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", ABISHA: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", BytecodeSHA: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", ProvenanceSHA: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
	if Verify(m) != nil {
		t.Fatal("valid manifest refused")
	}
	m.ChainID = 1
	if Verify(m) == nil {
		t.Fatal("wrong chain accepted")
	}
}
