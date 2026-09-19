package github

import (
	"context"
	"testing"
)

func TestTask_T067(t *testing.T) {
	if IntentMarker("issue", []byte("x")) == "" {
		t.Fatal("marker absent")
	}
	if Reconcile(context.Background(), func(context.Context) (bool, error) { return false, nil }) == nil {
		t.Fatal("unknown outcome accepted")
	}
}
