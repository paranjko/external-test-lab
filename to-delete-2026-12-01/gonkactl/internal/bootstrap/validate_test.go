package bootstrap

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

type schemaRedirectTransport struct{ origin string }

func (s schemaRedirectTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.String() == SchemaURL {
		request = request.Clone(request.Context())
		request.URL, _ = url.Parse(s.origin + "/schema")
	}
	return http.DefaultTransport.RoundTrip(request)
}

func TestValidateLocalPublishedAndStalePublication(t *testing.T) {
	genesis := `{"chain_id":"fixture"}`
	doc := Document{Schema: SchemaURL, ChainID: "fixture"}
	doc.Genesis.SHA256 = strings.TrimPrefix(digestOf(genesis), "sha256:")
	var publishedJSON, publishedENV []byte
	var failure string
	for i := 0; i < 2; i++ {
		id := strings.Repeat(fmt.Sprint(i), 40)
		var height atomic.Int32
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/schema":
				w.Write(embeddedSchema)
			case "/fixture/bootstrap.json":
				w.Write(publishedJSON)
			case "/fixture/bootstrap.env":
				w.Write(publishedENV)
			case "/chain-rpc/status":
				observedID := id
				if failure == "rpc" {
					observedID = "wrong"
				}
				fmt.Fprintf(w, `{"result":{"node_info":{"id":%q,"network":"fixture"},"sync_info":{"catching_up":false,"latest_block_height":%q}}}`, observedID, fmt.Sprint(height.Add(1)))
			case "/chain-rpc/genesis":
				if failure == "genesis" {
					fmt.Fprint(w, `{"result":{"genesis":{"chain_id":"wrong"}}}`)
					return
				}
				fmt.Fprint(w, `{"result":{"genesis":`+genesis+`}}`)
			case "/v1/participants":
				t.Error("validation must not query application health")
				if failure == "api" {
					fmt.Fprint(w, `{"participants":null}`)
					return
				}
				fmt.Fprint(w, `{"participants":[]}`)
			default:
				http.NotFound(w, r)
			}
		}))
		defer server.Close()
		doc.Seeds = append(doc.Seeds, Seed{NodeID: id, RPC: server.URL + "/chain-rpc", API: server.URL, P2P: "tcp://" + server.Listener.Addr().String()})
	}
	// An explicitly empty list, not null, is part of the v1 contract.
	raw, _ := json.Marshal(doc)
	raw = []byte(strings.ReplaceAll(string(raw), `"brokers":null`, `"brokers":[]`))
	publishedJSON, publishedENV = raw, doc.ENV()
	directory := t.TempDir()
	for suffix, body := range map[string][]byte{"json": raw, "env": publishedENV} {
		if err := os.WriteFile(filepath.Join(directory, "fixture."+suffix), body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	transport := NewTransport()
	transport.Client.Transport = schemaRedirectTransport{doc.Seeds[0].API}
	transport.RetryDelay = 0
	for _, mode := range []string{"local", "published", "compare", "stale", "rpc", "genesis", "api"} {
		t.Run(mode, func(t *testing.T) {
			failure = mode
			publishedJSON, publishedENV = raw, doc.ENV()
			options := ValidateOptions{ChainID: "fixture", BaseURL: doc.Seeds[0].API}
			if mode == "local" {
				options.Directory = directory
			}
			if mode != "local" && mode != "published" {
				options.ExpectedDirectory = directory
			}
			if mode == "stale" {
				publishedJSON = append(append([]byte(nil), raw...), '\n')
				publishedENV = []byte("stale")
			}
			report, err := transport.Validate(context.Background(), options)
			if err != nil || len(report.Results) != 1 {
				t.Fatalf("report=%+v error=%v", report, err)
			}
			result := report.Results[0]
			wantOK := mode == "local" || mode == "published" || mode == "compare" || mode == "api"
			if result.OK != wantOK {
				t.Fatalf("result=%+v", result)
			}
			if result.SoftwareDeclared == nil || *result.SoftwareDeclared {
				t.Fatal("incorrect absent software status")
			}
			stages := map[string]int{}
			failedStages := map[string]int{}
			for _, check := range result.Checks {
				stages[check.Stage]++
				if !check.OK {
					failedStages[check.Stage]++
				}
			}
			for _, stage := range []string{"rpc", "genesis", "p2p"} {
				if stages[stage] != 2 {
					t.Fatalf("failure skipped independent %s checks: %+v", stage, result)
				}
			}
			if stages["api"] != 0 || stages["block-progress"] != 0 {
				t.Fatal("network health leaked into bootstrap validation")
			}
			if mode == "rpc" || mode == "genesis" {
				if failedStages[mode] != 2 || len(failedStages) != 1 {
					t.Fatalf("incorrect failure aggregation: %+v", result)
				}
			}
			if mode == "stale" && (failedStages["publication-json"] != 1 || failedStages["publication-env"] != 1) {
				t.Fatal("byte drift must be reported for both files")
			}
			// Preserve the small report interface consumed by the monitor's
			// notification wrapper, without importing its implementation.
			encoded, err := json.Marshal(report)
			if err != nil {
				t.Fatal(err)
			}
			var wire map[string]any
			if err := json.Unmarshal(encoded, &wire); err != nil {
				t.Fatal(err)
			}
			network := wire["results"].([]any)[0].(map[string]any)
			if network["chain_id"] != "fixture" || network["ok"] != wantOK || wire["observed_at"] == "" {
				t.Fatalf("monitor report contract changed: %s", encoded)
			}
			if mode != "local" && network["bootstrap_url"] != doc.Seeds[0].API+"/fixture/bootstrap.json" {
				t.Fatal("notification link does not identify the published bootstrap")
			}
		})
	}
}
