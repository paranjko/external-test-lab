package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestGenesisRawBytes(t *testing.T) {
	for _, genesis := range []string{`{"chain_id":"test"}`, "{\n \"chain_id\": \"test\", \"unicode\": \"ж\"\n}"} {
		got, err := GenesisBytes([]byte(`{"result":{"before":0,"genesis": ` + genesis + `,"after":[]}}`))
		if err != nil || string(got) != genesis {
			t.Fatalf("got=%s err=%v", got, err)
		}
	}
	for _, bad := range []string{`null`, `{}`, `{"result":{"genesis":null}}`, `{"result":{"genesis":[]}}`, `{"result":{"genesis":{},"genesis":{}}}`} {
		if _, err := GenesisBytes([]byte(bad)); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}

func TestAllSeedChecksAndFailureAggregation(t *testing.T) {
	for _, mode := range []string{"healthy", "wrong-id", "wrong-chain", "wrong-genesis", "rpc-offline", "p2p-offline", "syncing", "stalled", "zero-height", "missing-sync", "api-offline"} {
		t.Run(mode, func(t *testing.T) {
			broken := mode == "wrong-id" || mode == "wrong-chain" || mode == "wrong-genesis" || mode == "rpc-offline" || mode == "p2p-offline"
			doc := Document{ChainID: "fixture"}
			genesis := `{"chain_id":"fixture"}`
			digest := sha256.Sum256([]byte(genesis))
			doc.Genesis.SHA256 = hex.EncodeToString(digest[:])
			for index := 0; index < 2; index++ {
				id := strings.Repeat(fmt.Sprint(index), 40)
				var requests atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					switch r.URL.Path {
					case "/chain-rpc/status":
						if mode == "rpc-offline" && index == 0 {
							http.Error(w, "offline", 503)
							return
						}
						observed := id
						network := "fixture"
						catchingUp := mode == "syncing" && index == 0
						height := requests.Add(1)
						if mode == "wrong-id" && index == 0 {
							observed = "wrong"
						}
						if mode == "wrong-chain" && index == 0 {
							network = "wrong"
						}
						if mode == "stalled" && index == 0 {
							height = 1
						}
						if mode == "zero-height" {
							height = 0
						}
						if mode == "missing-sync" {
							fmt.Fprintf(w, `{"result":{"node_info":{"id":%q,"network":%q}}}`, observed, network)
							return
						}
						fmt.Fprintf(w, `{"result":{"node_info":{"id":%q,"network":%q},"sync_info":{"catching_up":%t,"latest_block_height":%q}}}`, observed, network, catchingUp, fmt.Sprint(height))
					case "/chain-rpc/genesis":
						if mode == "wrong-genesis" && index == 0 {
							fmt.Fprint(w, `{"result":{"genesis":{"chain_id":"other"}}}`)
							return
						}
						fmt.Fprint(w, `{"result":{"genesis":`+genesis+`}}`)
					case "/v1/participants":
						t.Error("bootstrap must not query participant health API")
						http.Error(w, "unhealthy application", 503)
					default:
						http.NotFound(w, r)
					}
				}))
				defer server.Close()
				doc.Seeds = append(doc.Seeds, Seed{NodeID: id, RPC: server.URL + "/chain-rpc", API: server.URL, P2P: "tcp://" + server.Listener.Addr().String()})
				if mode == "p2p-offline" && index == 0 {
					closed := httptest.NewServer(http.NotFoundHandler())
					doc.Seeds[index].P2P = "tcp://" + closed.Listener.Addr().String()
					closed.Close()
				}
			}
			transport := NewTransport()
			transport.RetryDelay = 0
			result := Result{ChainID: doc.ChainID}
			transport.CheckSeeds(context.Background(), doc, &result)
			result.complete()
			want := 6
			if len(result.Checks) != want || result.OK == broken {
				t.Fatalf("result: %+v", result)
			}
			failures := 0
			for _, check := range result.Checks {
				if !check.OK {
					failures++
				}
			}
			if (broken && failures != 1) || (!broken && failures != 0) {
				t.Fatalf("unexpected failures: %+v", result)
			}
		})
	}
}
