package bootstrap

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

type guardianPolicyFixture struct {
	base           *updateFixture
	unavailable    map[string]bool
	missingHistory bool
}

func (f guardianPolicyFixture) RoundTrip(r *http.Request) (*http.Response, error) {
	if f.missingHistory && strings.HasPrefix(r.URL.Path, chainAPI+"epoch_group_data/") {
		return &http.Response{StatusCode: 404, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("missing history"))}, nil
	}
	if strings.HasPrefix(r.URL.Path, "/chain-api/cosmos/staking/") {
		return f.base.discovery.RoundTrip(r)
	}
	if r.URL.Path == "/v1/participants" && f.unavailable[r.URL.Hostname()] {
		return &http.Response{StatusCode: 503, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("offline"))}, nil
	}
	return f.base.RoundTrip(r)
}

func TestDevnetGuardianExclusionPolicy(t *testing.T) {
	for _, mode := range []string{"missing-staking", "unavailable-api", "too-few", "strict", "historical-fill", "missing-history", "historical-offline", "all-guardians", "missing-real-guardian"} {
		t.Run(mode, func(t *testing.T) {
			doc := discoveryDocument(t)
			f := &updateFixture{discovery: discoveryFixture{mode: "three-guardians"}, p2p: map[string]string{}}
			if mode == "missing-staking" || mode == "strict" {
				f.discovery.mode = "missing-staking"
			}
			if mode == "historical-fill" || mode == "missing-history" || mode == "historical-offline" {
				f.discovery.mode = "guardians"
			}
			if mode == "missing-real-guardian" {
				f.discovery.mode = mode
			}
			for i, host := range []string{"a.test", "b.test", "c.test"} {
				server := httptest.NewServer(http.NotFoundHandler())
				defer server.Close()
				f.p2p[host] = "tcp://" + server.Listener.Addr().String()
				doc.Seeds[i].P2P = f.p2p[host]
			}
			offline := map[string]bool{}
			if mode == "unavailable-api" || mode == "too-few" {
				offline["c.test"] = true
			}
			if mode == "too-few" || mode == "historical-fill" || mode == "missing-history" || mode == "historical-offline" {
				offline["b.test"] = true
			}
			if mode == "historical-offline" || mode == "missing-real-guardian" {
				offline["c.test"] = true
			}
			transport := NewTransport()
			transport.Client.Transport = guardianPolicyFixture{base: f, unavailable: offline, missingHistory: mode == "missing-history"}
			transport.RetryDelay = 0
			result := Result{}
			seeds, err := transport.discoverSeeds(context.Background(), doc, mode != "strict", 0, &result)
			want := mode == "missing-staking" || mode == "unavailable-api" || mode == "historical-fill" || mode == "all-guardians"
			if (err == nil) != want {
				t.Fatalf("seeds=%+v warnings=%v err=%v", seeds, result.Warnings, err)
			}
			if want && mode != "all-guardians" && (len(seeds) != 2 || len(result.Warnings) == 0) {
				t.Fatalf("missing explicit exclusion: %+v %+v", seeds, result)
			}
			if mode == "historical-fill" && (seeds[0].API != "https://a.test" || seeds[1].API != "https://c.test" || f.discovery.historyReads != 16) {
				t.Fatalf("guardian not retained or history not corroborated: %+v reads=%d", seeds, f.discovery.historyReads)
			}
			if want && mode != "historical-fill" && f.discovery.historyReads != 0 {
				t.Fatal("unnecessary history lookup with two healthy guardians")
			}
			if mode == "all-guardians" && (len(seeds) != 3 || len(result.Warnings) != 0) {
				t.Fatalf("healthy guardians were dropped: %+v %+v", seeds, result)
			}
		})
	}
}

func TestPolicyResolution(t *testing.T) {
	for _, tc := range []struct{ chain, requested, want string }{
		{"gonka-mainnet", "", "strict"}, {"GONKA-TESTNET", "auto", "testnet"},
		{"gonka-devnet-community", "auto", "devnet"}, {"testnet-devnet", "auto", "testnet"},
		{"gonka-testnet", "strict", "strict"}, {"private", "devnet", "devnet"},
	} {
		got, err := ResolvePolicy(tc.requested, tc.chain)
		if err != nil || got != tc.want {
			t.Fatalf("%+v: %s %v", tc, got, err)
		}
	}
	if _, err := ResolvePolicy("typo", "gonka-testnet"); err == nil {
		t.Fatal("invalid policy accepted")
	}
}

func TestTestnetResetPolicyAndReadOnlyValidation(t *testing.T) {
	for _, mode := range []string{"auto", "strict", "disagree", "wrong-chain", "wrong-genesis-chain", "invalid-id", "duplicate-id", "unavailable", "regression"} {
		t.Run(mode, func(t *testing.T) {
			doc := discoveryDocument(t)
			doc.ChainID = "gonka-testnet-fixture"
			doc.Software = nil
			doc.Seeds = nil
			for i := 0; i < 2; i++ {
				var calls atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if mode == "unavailable" && i == 1 {
						http.Error(w, "offline", 503)
						return
					}
					switch r.URL.Path {
					case "/chain-rpc/status":
						id := strings.Repeat(fmt.Sprint(i+3), 40)
						if mode == "invalid-id" {
							id = "invalid"
						}
						if mode == "duplicate-id" {
							id = strings.Repeat("3", 40)
						}
						chain := doc.ChainID
						if mode == "wrong-chain" {
							chain = "other"
						}
						height := 100
						if calls.Add(1) >= 4 && mode == "regression" {
							height = 99
						}
						fmt.Fprintf(w, `{"result":{"node_info":{"id":%q,"network":%q},"sync_info":{"catching_up":false,"latest_block_height":%q}}}`, id, chain, fmt.Sprint(height))
					case "/chain-rpc/genesis":
						generation := 2
						if mode == "disagree" && i == 1 {
							generation = 3
						}
						chain := doc.ChainID
						if mode == "wrong-genesis-chain" {
							chain = "other"
						}
						fmt.Fprintf(w, `{"result":{"genesis":{"chain_id":%q,"generation":%d}}}`, chain, generation)
					case "/v1/participants":
						fmt.Fprint(w, `{"participants":[]}`)
					default:
						http.NotFound(w, r)
					}
				}))
				defer server.Close()
				doc.Seeds = append(doc.Seeds, Seed{NodeID: strings.Repeat(fmt.Sprint(i+1), 40), RPC: server.URL + "/chain-rpc", API: server.URL, P2P: "tcp://" + server.Listener.Addr().String()})
			}
			directory := t.TempDir()
			original, _ := json.Marshal(doc)
			jsonPath := filepath.Join(directory, doc.ChainID+".json")
			envPath := filepath.Join(directory, doc.ChainID+".env")
			if err := os.WriteFile(jsonPath, original, 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(envPath, doc.ENV(), 0600); err != nil {
				t.Fatal(err)
			}
			transport := NewTransport()
			transport.RetryDelay = 0
			policy := "auto"
			if mode == "strict" {
				policy = "strict"
			}
			report, err := transport.Update(context.Background(), UpdateOptions{ChainID: doc.ChainID, Directory: directory, Policy: policy})
			if err != nil {
				t.Fatal(err)
			}
			want := mode == "auto"
			if len(report.Results) != 1 || report.Results[0].OK != want || report.Changed != want {
				t.Fatalf("%+v", report)
			}
			raw, env, err := readPair(directory, doc.ChainID)
			if err != nil {
				t.Fatal(err)
			}
			if !want && (!bytes.Equal(raw, original) || !bytes.Equal(env, doc.ENV())) {
				t.Fatal("failed reset changed pair")
			}
			if want {
				parsed, err := Parse(raw, nil)
				if err != nil || parsed.Genesis == doc.Genesis || parsed.Seeds[0].NodeID == doc.Seeds[0].NodeID {
					t.Fatalf("reset not applied: %v", err)
				}
				validation, err := transport.Validate(context.Background(), ValidateOptions{ChainID: doc.ChainID, Directory: directory})
				if err != nil || !validation.Results[0].OK {
					t.Fatalf("stationary testnet rejected: %+v %v", validation, err)
				}
				after, _ := os.ReadFile(jsonPath)
				if !bytes.Equal(raw, after) {
					t.Fatal("validate wrote data")
				}
			}
		})
	}
}
