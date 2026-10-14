package bootstrap

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

type discoveryFixture struct {
	mode         string
	historyReads int
}

type paginatedDiscoveryFixture struct {
	pages int
	calls int
}

func (f *paginatedDiscoveryFixture) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Path != chainAPI+"participant" || request.URL.Query().Get("pagination.limit") != "100" {
		return nil, fmt.Errorf("unexpected inventory request")
	}
	page := 0
	if key := request.URL.Query().Get("pagination.key"); key != "" {
		var err error
		page, err = strconv.Atoi(key)
		if err != nil {
			return nil, err
		}
	}
	f.calls++
	next := ""
	if page+1 < f.pages {
		next = strconv.Itoa(page + 1)
	}
	entries := make([]participant, 100)
	for index := range entries {
		entries[index] = participant{Address: fmt.Sprintf("account-%05d", page*100+index)}
	}
	raw, _ := json.Marshal(map[string]any{"participant": entries, "pagination": map[string]string{"next_key": next}})
	return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(string(raw)))}, nil
}

func TestDiscoveryInventoryBeyondTwoThousandRemainsBounded(t *testing.T) {
	for _, pages := range []int{71, maxParticipantPages, maxParticipantPages + 1} {
		fixture := &paginatedDiscoveryFixture{pages: pages}
		transport := NewTransport()
		transport.Client.Transport = fixture
		view, err := transport.discoveryView(context.Background(), "https://source.test", false)
		if pages <= maxParticipantPages {
			if err != nil || len(view.Participants) != pages*100 || fixture.calls != pages {
				t.Fatalf("pages=%d participants=%d calls=%d err=%v", pages, len(view.Participants), fixture.calls, err)
			}
		} else if err == nil || fixture.calls != maxParticipantPages {
			t.Fatalf("unbounded or partial inventory accepted: calls=%d err=%v", fixture.calls, err)
		}
	}
}

func (f *discoveryFixture) RoundTrip(request *http.Request) (*http.Response, error) {
	host := strings.TrimSuffix(request.URL.Hostname(), ".test")
	index := map[string]string{"a": "1", "b": "2", "c": "3"}[host]
	if index == "" {
		return nil, fmt.Errorf("unexpected fixture host")
	}
	var body string
	switch path := request.URL.Path; {
	case path == "/chain-rpc/status":
		id := strings.Repeat(index, 40)
		if f.mode == "changed-node-id" && host == "b" {
			id = strings.Repeat("4", 40)
		}
		key := "key-" + host
		if f.mode == "wrong-validator-key" && host == "b" {
			key = "wrong"
		}
		body = fmt.Sprintf(`{"result":{"node_info":{"id":%q,"network":"gonka-devnet-community","listen_addr":%q},"sync_info":{"catching_up":false,"latest_block_height":"100"},"validator_info":{"pub_key":{"value":%q}}}}`, id, "tcp://"+host+".test:5000", key)
	case path == "/chain-rpc/genesis":
		body = `{"result":{"genesis":{"chain_id":"gonka-devnet-community"}}}`
	case path == chainAPI+"params":
		body = `{"params":{"genesis_guardian_params":{"guardian_addresses":["guardian-a","guardian-b"]}}}`
		if f.mode == "empty-guardians" || f.mode == "missing-history" {
			body = `{"params":{"genesis_guardian_params":{"guardian_addresses":[]}}}`
		}
		if f.mode == "missing-guardians" {
			body = `{"params":{}}`
		}
		if f.mode == "disagreement" && host == "b" {
			body = `{"params":{"genesis_guardian_params":{"guardian_addresses":["guardian-a"]}}}`
		}
	case strings.HasPrefix(path, "/chain-api/cosmos/staking/v1beta1/validators/guardian-"):
		guardian := strings.TrimPrefix(path, "/chain-api/cosmos/staking/v1beta1/validators/")
		body = fmt.Sprintf(`{"validator":{"operator_address":%q,"consensus_pubkey":{"key":%q}}}`, guardian, "key-"+strings.TrimPrefix(guardian, "guardian-"))
	case path == chainAPI+"participant":
		body = `{"participant":[{"address":"account-a","inference_url":"https://a.test","validator_key":"key-a","status":"ACTIVE"},{"address":"account-b","inference_url":"https://b.test","validator_key":"key-b","status":"ACTIVE"},{"address":"account-c","inference_url":"https://c.test","validator_key":"key-c","status":"ACTIVE"}],"pagination":{"next_key":null}}`
	case path == chainAPI+"epoch_info":
		body = `{"latest_epoch":{"index":"10"}}`
	case strings.HasPrefix(path, chainAPI+"epoch_group_data/"):
		f.historyReads++
		if f.mode == "missing-history" {
			return &http.Response{StatusCode: 404, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
		epoch := strings.TrimPrefix(path, chainAPI+"epoch_group_data/")
		weight := "1"
		if epoch == "2" {
			weight = "0"
		}
		body = fmt.Sprintf(`{"epoch_group_data":{"epoch_index":%q,"validation_weights":[{"member_address":"account-a","weight":"1"},{"member_address":"account-b","weight":%q},{"member_address":"account-c","weight":"1"}]}}`, epoch, weight)
	default:
		return nil, fmt.Errorf("unexpected fixture path %s", path)
	}
	return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
}

func discoveryDocument(t *testing.T) Document {
	t.Helper()
	base, err := Parse(fixture(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	base.Genesis.SHA256 = strings.TrimPrefix(digestOf(`{"chain_id":"gonka-devnet-community"}`), "sha256:")
	base.Seeds = nil
	for index, host := range []string{"a", "b", "c"} {
		base.Seeds = append(base.Seeds, Seed{NodeID: strings.Repeat(fmt.Sprint(index+1), 40), RPC: "https://" + host + ".test/chain-rpc", API: "https://" + host + ".test", P2P: "tcp://" + host + ".test:5000"})
	}
	return base
}

func TestGuardianAndHistoricalDiscovery(t *testing.T) {
	for _, mode := range []string{"guardians", "changed-node-id", "empty-guardians", "missing-guardians", "missing-history", "disagreement", "wrong-validator-key"} {
		t.Run(mode, func(t *testing.T) {
			transport := NewTransport()
			fixture := &discoveryFixture{mode: mode}
			transport.Client.Transport = fixture
			transport.RetryDelay = 0
			doc := discoveryDocument(t)
			seeds, err := transport.DiscoverSeeds(context.Background(), doc)
			wantSuccess := mode == "guardians" || mode == "changed-node-id" || mode == "empty-guardians"
			if (err == nil) != wantSuccess {
				t.Fatalf("seeds=%+v err=%v", seeds, err)
			}
			if !wantSuccess {
				if mode == "missing-guardians" && fixture.historyReads != 0 {
					t.Fatal("missing guardians triggered historical fallback")
				}
				return
			}
			if len(seeds) != 2 || seeds[0].API != "https://a.test" {
				t.Fatalf("seeds=%+v", seeds)
			}
			wantSecond := "https://b.test"
			if mode == "empty-guardians" {
				wantSecond = "https://c.test"
				if fixture.historyReads != 16 {
					t.Fatal("history not verified across both sources")
				}
			}
			if seeds[1].API != wantSecond {
				t.Fatalf("seeds=%+v", seeds)
			}
			if mode == "changed-node-id" && seeds[1].NodeID != strings.Repeat("4", 40) {
				t.Fatal("stale bootstrap node ID not refreshed")
			}
			if doc.Seeds[1].NodeID != strings.Repeat("2", 40) {
				t.Fatal("input document mutated")
			}
		})
	}
}

func TestHistoryInsufficiencyAndStableTieBreak(t *testing.T) {
	participants := []participant{{Address: "b", API: "https://b.test", Status: "ACTIVE"}, {Address: "a", API: "https://a.test", Status: "ACTIVE"}}
	epochs := make([][]weightedParticipant, historyEpochs)
	for index := range epochs {
		epochs[index] = []weightedParticipant{{Address: "a", Weight: "1"}, {Address: "b", Weight: "1"}}
	}
	ranked, err := rankHistory(participants, epochs, map[string]bool{"https://b.test": true})
	if err != nil || !reflect.DeepEqual(ranked, participants) {
		t.Fatalf("ranked=%+v err=%v", ranked, err)
	}
	if _, err := rankHistory(participants, epochs[:7], nil); err == nil {
		t.Fatal("incomplete history accepted")
	}
	epochs[0] = append(epochs[0], epochs[0][0])
	if _, err := rankHistory(participants, epochs, nil); err == nil {
		t.Fatal("duplicate epoch member accepted")
	}
	encoded, _ := json.Marshal(discoveryDocument(t))
	if _, err := Parse(encoded, nil); err != nil {
		t.Fatal(err)
	}
}
