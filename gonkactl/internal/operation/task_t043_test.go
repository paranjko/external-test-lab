package operation

import (
	"testing"
	"time"
)

func TestTask_T043(t *testing.T) {
	b := OwnerBundle{Kind: "x", TargetRole: "edge", ChainID: "c", GenesisRawSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", InputsSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
	if b.Validate(time.Now()) != nil {
		t.Fatal("valid bundle refused")
	}
	if AllowlistedReceipt("relative", "op") == nil {
		t.Fatal("relative receipt accepted")
	}
}
