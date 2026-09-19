package distribution

import "testing"

func TestTask_T076(t *testing.T) {
	if !ReadbackOK(200, 200, 200) {
		t.Fatal("readback rejected")
	}
	if _, e := RollbackTarget("2", "1", map[string]bool{"1": true}); e != nil {
		t.Fatal(e)
	}
}
