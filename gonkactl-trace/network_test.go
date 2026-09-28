package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestNetworkCollectionArgumentsResolveBootstrapAliasAndHEAD(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/gonka-mainnet/bootstrap.json":
			fmt.Fprintf(w, `{"seeds":[{"node_id":"mainnet-seed","rpc":%q}]}`, serverURL(r)+"/chain-rpc")
		case "/chain-rpc/status":
			fmt.Fprint(w, `{"result":{"sync_info":{"latest_block_height":"200"}}}`)
		case "/chain-rpc/block":
			fmt.Fprintf(w, `{"result":{"block":{"header":{"chain_id":"gonka-mainnet","height":%q}}}}`, r.URL.Query().Get("height"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	old := bootstrapBaseURL
	bootstrapBaseURL = server.URL
	t.Cleanup(func() { bootstrapBaseURL = old })

	c, from, to, err := networkCollectionArguments([]string{"mainnet", "HEAD~100", "+10"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Chain != "gonka-mainnet" || c.Nodes[0].RPC != server.URL+"/chain-rpc" || c.Nodes[0].REST != server.URL+"/chain-api" || from != 100 || to != 110 {
		t.Fatalf("unexpected network selection: %+v %d %d", c, from, to)
	}
}

func TestNetworkCollectionArgumentsRejectsWrongChain(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/gonka-mainnet/bootstrap.json":
			fmt.Fprintf(w, `{"seeds":[{"node_id":"mainnet-seed","rpc":%q}]}`, serverURL(r)+"/chain-rpc")
		case "/chain-rpc/status":
			fmt.Fprint(w, `{"result":{"sync_info":{"latest_block_height":"200"}}}`)
		case "/chain-rpc/block":
			fmt.Fprint(w, `{"result":{"block":{"header":{"chain_id":"wrong","height":"200"}}}}`)
		}
	}))
	defer server.Close()
	old := bootstrapBaseURL
	bootstrapBaseURL = server.URL
	t.Cleanup(func() { bootstrapBaseURL = old })
	if _, _, _, err := networkCollectionArguments([]string{"gonka-mainnet", "100", "101"}); err == nil {
		t.Fatal("accepted a bootstrap seed for the wrong chain")
	}
}

func TestNetworkCollectionArgumentsFallsBackToVerifiedBootstrapSeed(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/gonka-mainnet/bootstrap.json":
			fmt.Fprintf(w, `{"seeds":[{"node_id":"unavailable","rpc":%q},{"node_id":"working","rpc":%q}]}`, serverURL(r)+"/first/chain-rpc", serverURL(r)+"/second/chain-rpc")
		case "/first/chain-rpc/status":
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
		case "/second/chain-rpc/status":
			fmt.Fprint(w, `{"result":{"sync_info":{"latest_block_height":"200"}}}`)
		case "/second/chain-rpc/block":
			fmt.Fprintf(w, `{"result":{"block":{"header":{"chain_id":"gonka-mainnet","height":%q}}}}`, r.URL.Query().Get("height"))
		}
	}))
	defer server.Close()
	old := bootstrapBaseURL
	bootstrapBaseURL = server.URL
	t.Cleanup(func() { bootstrapBaseURL = old })
	c, _, _, err := networkCollectionArguments([]string{"mainnet", "HEAD~1"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Nodes[0].ID != "working" || c.Nodes[0].RPC != server.URL+"/second/chain-rpc" {
		t.Fatalf("fallback did not select the verified seed: %+v", c.Nodes[0])
	}
}

func TestNetworkCollectionArgumentsAcceptsDirectRPC(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/chain-rpc/status":
			fmt.Fprint(w, `{"result":{"sync_info":{"latest_block_height":"200"}}}`)
		case "/chain-rpc/block":
			fmt.Fprintf(w, `{"result":{"block":{"header":{"chain_id":"gonka-mainnet","height":%q}}}}`, r.URL.Query().Get("height"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	c, from, to, err := networkCollectionArguments([]string{server.URL + "/chain-rpc", "HEAD~100"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Chain != "gonka-mainnet" || c.Nodes[0].RPC != server.URL+"/chain-rpc" || c.Nodes[0].REST != server.URL+"/chain-api" || from != 100 || to != 200 {
		t.Fatalf("unexpected direct RPC selection: %+v %d %d", c, from, to)
	}
}

func TestResolveNetworkAliasAndHeight(t *testing.T) {
	for input, want := range map[string]string{"mainnet": "gonka-mainnet", "gonka-mainnet": "gonka-mainnet", "devnet": "gonka-devnet-community", "testnet": "gonka-testnet"} {
		if got, err := resolveNetworkAlias(input); err != nil || got != want {
			t.Fatalf("resolve %s: %q %v", input, got, err)
		}
	}
	if got, err := resolveHeight("HEAD~100", 200); err != nil || got != 100 {
		t.Fatalf("relative height: %d %v", got, err)
	}
	for _, value := range []string{"HEAD~200", "HEAD~-1", "HEAD~x", "0"} {
		if _, err := resolveHeight(value, 200); err == nil {
			t.Fatalf("accepted %s", value)
		}
	}
}

func TestReportMainnetRelativeRangeFromBootstrap(t *testing.T) {
	t.Chdir(t.TempDir())
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		height := r.URL.Query().Get("height")
		switch r.URL.Path {
		case "/gonka-mainnet/bootstrap.json":
			fmt.Fprintf(w, `{"seeds":[{"node_id":"mainnet-seed","rpc":%q}]}`, serverURL(r)+"/chain-rpc")
		case "/chain-rpc/status":
			fmt.Fprint(w, `{"result":{"sync_info":{"latest_block_height":"3"}}}`)
		case "/chain-rpc/block":
			fmt.Fprintf(w, `{"result":{"block_id":{"hash":"A"},"block":{"header":{"height":%q,"chain_id":"gonka-mainnet","time":"2026-09-09T18:59:00Z"}}}}`, height)
		case "/chain-rpc/validators":
			fmt.Fprintf(w, `{"result":{"block_height":%q,"validators":[],"total":"0"}}`, height)
		case "/chain-rpc/commit", "/chain-rpc/block_results", "/chain-rpc/abci_info", "/chain-rpc/consensus_state", "/chain-rpc/dump_consensus_state":
			fmt.Fprint(w, `{"result":{}}`)
		case "/chain-api/productscience/inference/inference/params":
			w.Header().Set("x-cosmos-block-height", r.Header.Get("x-cosmos-block-height"))
			fmt.Fprint(w, `{"params":{"epoch_params":{"poc_stage_duration":"1","poc_validation_delay":"0","poc_validation_duration":"1"}}}`)
		case "/chain-api/productscience/inference/inference/current_epoch_group_data":
			w.Header().Set("x-cosmos-block-height", r.Header.Get("x-cosmos-block-height"))
			fmt.Fprint(w, `{"epoch_group_data":{"poc_start_block_height":"1","epoch_index":"1","epoch_group_id":"1"}}`)
		default:
			if r.URL.Path == "/chain-api/productscience/inference/inference/participant" || r.URL.Path == "/chain-api/cosmos/staking/v1beta1/validators" || r.URL.Path == "/chain-api/cosmos/group/v1/group_members/1" {
				w.Header().Set("x-cosmos-block-height", r.Header.Get("x-cosmos-block-height"))
				fmt.Fprint(w, `{"pagination":{"next_key":null}}`)
				return
			}
			w.Header().Set("x-cosmos-block-height", r.Header.Get("x-cosmos-block-height"))
			fmt.Fprint(w, `{}`)
		}
	}))
	defer server.Close()
	old := bootstrapBaseURL
	bootstrapBaseURL = server.URL
	t.Cleanup(func() { bootstrapBaseURL = old })

	if err := runReport([]string{"mainnet", "HEAD~2"}); err != nil {
		t.Fatal(err)
	}
	paths, err := filepath.Glob(".gonkactl-trace/sample-*/derived/perfetto/application-*/report.html")
	if err != nil || len(paths) != 1 {
		t.Fatalf("report output: %v %v", paths, err)
	}
	if info, err := os.Stat(paths[0]); err != nil || info.Size() == 0 {
		t.Fatalf("report missing: %v", err)
	}
}

func serverURL(r *http.Request) string {
	return "http://" + r.Host
}
