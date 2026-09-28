package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestConsensusAddressChecksum(t *testing.T) {
	good := "gonkavalcons1ylap2d0n7a8ptzj46fgkh40mn6jfag2fc44s82"
	if got := consensusAddress(good); got != "27FA1535F3F74E158A55D2516BD5FB9EA49EA149" {
		t.Fatal(got)
	}
	for _, bad := range []string{good[:len(good)-1] + "3", strings.Replace(good, "valcons", "valoper", 1), "", strings.ToUpper(good)} {
		if consensusAddress(bad) != "" {
			t.Fatal("accepted invalid address", bad)
		}
	}
}

func TestPerfettoProcessGenerationBoundary(t *testing.T) {
	created := timestamp("2026-09-10T10:00:00Z")
	r := Receipt{Source: "docker:core", Process: &ProcessMetadata{ID: strings.Repeat("a", 64), Created: iso(created)}}
	e := Event{Time: created.Add(-time.Second)}
	annotateProcess(&e, r)
	if e.Attr["process.generation"] != "" {
		t.Fatal("current container applied backwards")
	}
	e.Time = created.Add(time.Second)
	annotateProcess(&e, r)
	id, label, _ := processActor(ConsensusObservation{Observer: "node3", Attributes: e.Attr}, "core")
	if !strings.Contains(id, "container-"+r.Process.ID) || !strings.Contains(label, "aaaaaaaaaaaa") {
		t.Fatal(id, label)
	}
	id, _, _ = processActor(ConsensusObservation{Observer: "node3", Source: "old.txt#L1"}, "core")
	if strings.Contains(id, "container-") || strings.Contains(id, "generation-unknown") {
		t.Fatal(id)
	}
}

func TestPerfettoLivenessLog(t *testing.T) {
	c := fixtureConsensus()
	line := "2026-09-09T18:55:45Z INF slashing and jailing validator due to liveness fault height=306511 module=x/slashing threshold=50 validator=gonkavalcons1ylap2d0n7a8ptzj46fgkh40mn6jfag2fc44s82 jailed_until=2026-09-09T19:05:39Z"
	es := normalizeLog(line, "node0", "core", "test.log", 306500, 306552, time.Time{}, time.Time{}, false)
	c.readEvents(es)
	os := c.height(306511).Observations
	if len(os) != 1 || os[0].Kind != "validator.jailed.liveness" || os[0].Validator != "27FA1535F3F74E158A55D2516BD5FB9EA49EA149" || os[0].Attributes["threshold"] != "50" {
		t.Fatal(os)
	}
}

func TestPerfettoABCIJailNotZeroSlash(t *testing.T) {
	c := fixtureConsensus()
	attrs := []any{map[string]any{"key": "address", "value": "gonkavalcons1ylap2d0n7a8ptzj46fgkh40mn6jfag2fc44s82"}, map[string]any{"key": "reason", "value": "missing_signature"}, map[string]any{"key": "jailed", "value": "true"}, map[string]any{"key": "burned_coins", "value": "0"}}
	c.readLivenessEvents(map[string]any{"finalize_block_events": []any{map[string]any{"type": "slash", "attributes": attrs}}}, 7, Receipt{Node: "node3", Path: "rpc.json"})
	o := c.height(7).Observations[len(c.height(7).Observations)-1]
	if o.Kind != "validator.jailed.liveness" || !o.Time.IsZero() || o.Attributes["burned_coins"] != "0" {
		t.Fatal(o)
	}
}

func TestPerfettoMembershipSamples(t *testing.T) {
	c := fixtureConsensus()
	c.Start = timestamp("2026-09-09T18:00:00Z")
	c.End = c.Start.Add(time.Minute)
	c.height(7).HeaderTime = c.Start
	a := makeAnalysis(c, "test", "sample")
	found := false
	for _, m := range a.Measurements {
		if m.Metric == "membership.active_power" && m.Height == 7 && m.Target == "total" {
			found = true
			if *m.Value != 135 || m.TraceNS != "0" {
				t.Fatal(m)
			}
		}
	}
	if !found {
		t.Fatal("missing voting power samples")
	}
}

func TestHistorySelectionBoundary(t *testing.T) {
	c := Config{Nodes: []Node{{ID: "node0"}}, History: []HistoryRequest{{Node: "node0", Method: "block", Height: 10}}}
	if validateHistory(c, 10, 20) != nil {
		t.Fatal("valid selection rejected")
	}
	c.History = append(c.History, c.History[0])
	if validateHistory(c, 10, 20) == nil {
		t.Fatal("duplicate accepted")
	}
	c.History = c.History[:1]
	c.History[0].Method = "broadcast_tx_commit"
	if validateHistory(c, 10, 20) == nil {
		t.Fatal("write method accepted")
	}
}

func TestPerfettoLogDetailProjection(t *testing.T) {
	c := fixtureConsensus()
	c.LogDetailRanges = []HeightRange{{From: 7, To: 7}}
	for _, o := range []ConsensusObservation{
		{Height: 8, Kind: "signer.signed", Source: "signer.log#L1"},
		{Height: 8, Kind: "validator.jailed.liveness", Source: "core.log#L2"},
		{Height: 8, Kind: "vote.certificate", Source: "commit.json#/signatures/1"},
	} {
		c.add(o)
	}
	if len(c.height(8).Observations) != 2 {
		t.Fatal(c.height(8).Observations)
	}
}

func TestPerfettoExtendedHistoryArtifact(t *testing.T) {
	path := os.Getenv("GONKACTL_HISTORY_ANALYSIS")
	if path == "" {
		t.Skip("extended artifact is qualified by make qualify-history with HISTORY_ANALYSIS")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var a PFAnalysis
	if err = json.Unmarshal(b, &a); err != nil {
		t.Fatal(err)
	}
	if a.Meta.From != 131833 || a.Meta.To != 306552 {
		t.Fatal(a.Meta)
	}
	node2 := "EEFA332A5E82A8B0A22B72B1581ED4F0BE6D9F83"
	node3 := "9777352BACFC5ABA9F296D882B5EDE4F40013EFD"
	signed := map[int64]bool{}
	jails := map[int64]bool{}
	node3Signed, knownContainer := false, false
	for _, e := range a.Events {
		if e.Kind == "vote.certificate" && e.ValidatorID != nil {
			if *e.ValidatorID == node2 && e.Height >= 131833 && e.Height <= 131972 {
				signed[e.Height] = true
			}
			if *e.ValidatorID == node3 {
				node3Signed = true
			}
		}
		if e.Kind == "validator.jailed.liveness" {
			jails[e.Height] = true
		}
		if strings.HasPrefix(e.ActorID, "core@node0/container-") {
			knownContainer = true
		}
		if strings.Contains(e.ActorID, "generation-unknown") {
			t.Fatal("placeholder generation survived", e.ActorID)
		}
	}
	if len(signed) != 140 || !node3Signed || !knownContainer {
		t.Fatal(len(signed), node3Signed, knownContainer)
	}
	for _, h := range []int64{209141, 209421, 209701, 209841, 209981, 210121, 210261, 306231, 306371, 306511} {
		if !jails[h] {
			t.Fatal("missing indexed liveness jail", h)
		}
	}
	values := map[int64]int64{}
	for _, m := range a.Measurements {
		if m.Metric == "membership.active_power" && m.Target == "total" && m.Value != nil {
			values[m.Height] = *m.Value
		}
	}
	if values[306552] != 405 || values[306553] != 135 {
		t.Fatal("final power transition missing", values[306552], values[306553])
	}
}
