//go:build gnklab0002_live

package cli

import (
	"context"
	"strings"
	"sync"
	"testing"
)

func TestIncidentNativeTransportRejectsUntrustedTokens(t *testing.T) {
	for _, tc := range []struct{ node, phase, digest string }{
		{"node0;id", "status", strings.Repeat("a", 64)},
		{"node0", "status;id", strings.Repeat("a", 64)},
		{"node0", "status", "$(id)"},
		{"node0", "status", strings.Repeat("A", 64)},
		{"node9", "repair", strings.Repeat("a", 64)},
	} {
		if _, err := runIncidentAgent(context.Background(), tc.node, tc.phase, "", "", tc.digest); err == nil {
			t.Fatalf("unsafe native invocation accepted: %+v", tc)
		}
	}
}

func TestIncidentNativeHostRefusesWrongExecutableBeforeEffects(t *testing.T) {
	cmd := NewRoot()
	cmd.SetArgs([]string{"incident-recovery-local", "--node", "node0", "--phase", "repair", "--self-sha256", strings.Repeat("0", 64), "--apply"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("wrong native agent identity accepted")
	}
}

func TestIncidentNativeOutputIsBoundedAndConcurrent(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &incidentAgentOutput{limit: 32, cancel: cancel}
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, _ = out.Write([]byte("12345678"))
		}()
	}
	group.Wait()
	if len(out.Bytes()) > 32 || ctx.Err() == nil {
		t.Fatal("output overflow did not cancel the transport")
	}
}
