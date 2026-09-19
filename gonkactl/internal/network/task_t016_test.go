package network

import (
	"testing"
)

func TestTask_T016(t *testing.T) {
	v := []Observation{{"a", "1.1.1.1", "r1", "c1", "d1", "A", true}, {"b", "1.1.1.2", "r2", "c1", "d1", "A", true}, {"c", "1.1.1.3", "r3", "c2", "d2", "B", true}}
	got, err := SelectRuntime(v, "gonka-devnet-community")
	if err != nil || got.Core != "c1" {
		t.Fatalf("%v %#v", err, got)
	}
	if err := ValidateLineage([]string{"A", "A", "B", "C"}); err == nil {
		t.Fatal("A,A,B,C accepted")
	}
}
