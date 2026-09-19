package network

import (
	"context"
	"encoding/json"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"testing"
)

func TestTask_T015(t *testing.T) {
	raw := []byte(`{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://one.example/chain-rpc","p2p":"tcp://one.example:5000","api":"https://one.example"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://two.example/chain-rpc","p2p":"tcp://two.example:5000"}],"brokers":[]}`)
	if _, err := ParseBootstrap(raw); err != nil {
		t.Fatal(err)
	}
	duplicate := bytesReplace(raw, []byte(`"chain_id":"gonka-fixture"`), []byte(`"chain_id":"gonka-fixture","chain_id":"duplicate"`))
	if _, err := ParseBootstrap(duplicate); err == nil {
		t.Fatal("duplicate accepted")
	}
	input, _ := json.Marshal(map[string]any{"descriptor": json.RawMessage(raw)})
	result, err := NewBootstrapDescriptorValidationHandler(contracts.Dependencies{}).Execute(context.Background(), input)
	if err != nil || result.Code != "bootstrap_valid" {
		t.Fatalf("%v %#v", err, result)
	}
}
func bytesReplace(in, old, new []byte) []byte {
	for i := 0; i+len(old) <= len(in); i++ {
		same := true
		for j := range old {
			if in[i+j] != old[j] {
				same = false
				break
			}
		}
		if same {
			return append(append(append([]byte{}, in[:i]...), new...), in[i+len(old):]...)
		}
	}
	return in
}
