package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func fixtureConsensus() ConsensusTimeline {
	c := ConsensusTimeline{Chain: "fixture", From: 7, To: 7, Heights: map[int64]*ConsensusHeight{}}
	vs := []ConsensusValidator{{Address: strings.Repeat("A", 40), Power: 54}, {Address: strings.Repeat("B", 40), Power: 54}, {Address: strings.Repeat("C", 40), Power: 27}}
	for _, node := range []string{"n1", "n2"} {
		c.height(7).Sets[node] = ConsensusSet{Height: 7, Observer: node, Total: 135, Complete: true, Validators: vs}
	}
	return c
}
func TestConsensusUniqueWeightAndObservers(t *testing.T) {
	c := fixtureConsensus()
	a, b := strings.Repeat("A", 40), strings.Repeat("C", 40)
	target := strings.Repeat("F", 64) + ":1:" + strings.Repeat("E", 64)
	for _, node := range []string{"n1", "n2"} {
		c.add(ConsensusObservation{Height: 7, Round: 0, Phase: "PREVOTE", Kind: "vote.received", Validator: a, Target: target, Observer: node})
	}
	c.add(ConsensusObservation{Height: 7, Round: 0, Phase: "PREVOTE", Kind: "vote.received", Validator: b, Target: target, Observer: "n1"})
	c.correlate()
	tally := c.tally(7, 0, "PREVOTE", target, "historical-union", "", "")
	if tally.Power != 81 || tally.Quorum != 91 || tally.Deficit != 10 || len(c.Votes) != 2 {
		t.Fatal(tally, c.Votes)
	}
	if got := c.tally(7, 0, "PREVOTE", target, "received", "n2", "").Power; got != 54 {
		t.Fatal("union leaked into observer", got)
	}
}
func TestConsensusTargetsNilAndUnknown(t *testing.T) {
	c := fixtureConsensus()
	vs := c.Heights[7].Sets["n1"].Validators
	for i, v := range vs {
		target := []string{"nil", "unknown:1234", "nil"}[i]
		c.Votes = append(c.Votes, ConsensusVote{Height: 7, Round: 0, Type: "PRECOMMIT", Validator: v.Address, Target: target, Observations: []ConsensusObservation{{Kind: "vote.received", Observer: "n1"}}})
	}
	if c.tally(7, 0, "PRECOMMIT", "any", "received", "n1", "").Power != 135 {
		t.Fatal("any votes")
	}
	nilVote := c.tally(7, 0, "PRECOMMIT", "nil", "received", "n1", "")
	if nilVote.Power != 81 || !strings.Contains(nilVote.Condition, "cannot commit") {
		t.Fatal(nilVote)
	}
	if !strings.Contains(c.tally(7, 0, "PRECOMMIT", "unknown:1234", "received", "n1", "").Condition, "unresolved") {
		t.Fatal("unknown target became certificate")
	}
}

func TestConsensusPrefixIndexAndReceptionGrowth(t *testing.T) {
	c := fixtureConsensus()
	a := timestamp("2026-09-09T18:59:33Z")
	for i, input := range []struct{ address, index string }{{strings.Repeat("A", 12), "0"}, {strings.Repeat("A", 12), "0"}, {strings.Repeat("C", 12), "2"}, {strings.Repeat("B", 12), "0"}} {
		c.add(ConsensusObservation{Height: 7, Round: 0, Phase: "PREVOTE", Kind: "vote.received", Validator: input.address, Target: "nil", Observer: "n1", Time: a.Add(time.Duration(i) * time.Second), Attributes: map[string]string{"validator.index": input.index}})
	}
	c.correlate()
	tally := c.tally(7, 0, "PREVOTE", "any", "received", "n1", "")
	if tally.Power != 81 || len(tally.Unknown) != 1 {
		t.Fatal(tally)
	}
	points := c.growth(7, 0, "PREVOTE")
	if len(points) != 4 || points[0].Tally.Power != 54 || points[2].Tally.Power != 81 || !points[2].Time.Equal(a.Add(2*time.Second)) {
		t.Fatal(points)
	}
}
func TestConsensusAmbiguousPrefix(t *testing.T) {
	c := fixtureConsensus()
	for _, suffix := range []string{"A", "B"} {
		c.add(ConsensusObservation{Height: 7, Round: 0, Phase: "PROPOSE", Target: strings.Repeat("F", 64) + ":1:" + strings.Repeat(suffix, 64)})
	}
	if !strings.HasPrefix(c.resolve(7, 0, "FFFF"), "unknown:") {
		t.Fatal("ambiguous BlockID resolved")
	}
}
func TestConsensusEmptyRoundAndAbsentVote(t *testing.T) {
	c := fixtureConsensus()
	m := map[string]any{"round_state": map[string]any{"height/round/step": "7/0/4", "height_vote_set": []any{map[string]any{"round": float64(1), "prevotes": []any{"nil-Vote"}, "precommits": []any{"nil-Vote"}}}}}
	c.readSnapshot(m, "consensus_state", Receipt{Node: "n1", Collected: time.Now()})
	if c.Heights[7].Rounds[1] {
		t.Fatal("empty bucket became a round")
	}
	for _, o := range c.Heights[7].Observations {
		if o.Kind == "vote.snapshot" {
			t.Fatal("absent vote became nil-target vote")
		}
	}
}
func TestConsensusParsingContextAndStaleTimer(t *testing.T) {
	c := fixtureConsensus()
	a := timestamp("2026-09-09T18:59:33Z")
	messages := []Event{{Node: "n1", Component: "core", Time: a, Message: "EpochGroupChanged blockHeight=7 module=x/inference"}, {Node: "n1", Component: "core", Time: a.Add(time.Millisecond), Message: "EpochGroupChanged computeResult=[] module=x/inference"}, {Node: "n1", Component: "tmkms", Time: a.Add(time.Second), Message: "signed PreVote:ABCDEF at h/r/s 7/0/1"}, {Node: "n1", Component: "core", Time: a.Add(2 * time.Second), Message: "Timed out height=7 round=0 step=RoundStepPropose module=consensus"}, {Node: "n1", Component: "core", Time: a, Message: "devshard_escrow_lock height=7 module=x/inference"}, {Node: "n1", Component: "core", Time: a, Message: `iterating validator unbonding_height=900 module=x/staking`}}
	c.readEvents(messages)
	stale, epochs := 0, 0
	for _, o := range c.Heights[7].Observations {
		if o.Kind == "timer.stale" {
			stale++
		}
		if strings.HasPrefix(o.Kind, "epoch.") {
			epochs++
		}
		if o.Phase == "LOCK" {
			t.Fatal("escrow lock became consensus lock")
		}
	}
	if stale != 1 || epochs != 2 || c.Heights[900] != nil {
		t.Fatal(c.Heights)
	}
}
func TestConsensusCommitFlagsAndHeaderTime(t *testing.T) {
	c := fixtureConsensus()
	target := map[string]any{"hash": strings.Repeat("F", 64), "parts": map[string]any{"total": 1, "hash": strings.Repeat("E", 64)}}
	c.readCommit(map[string]any{"height": "7", "round": 0, "block_id": target, "signatures": []any{map[string]any{"block_id_flag": 1}, map[string]any{"block_id_flag": 3, "validator_address": strings.Repeat("A", 40), "signature": "x", "timestamp": "2026-09-09T18:59:28Z"}}}, Receipt{Node: "n2"}, "commit")
	c.correlate()
	if len(c.Votes) != 1 || c.Votes[0].Target != "nil" || c.Votes[0].Validator != strings.Repeat("A", 40) {
		t.Fatal(c.Votes)
	}
}

// The historical regression contract must not depend on the owner's latest
// collection window. A new collect/report invocation may legitimately be shorter.
func savedIncidentInput() string {
	if input := os.Getenv("GONKACTL_TRACE_SAVED_SAMPLE"); input != "" {
		return input
	}
	return datasetDir + "/sample-3515724092/dataset.json"
}
func TestSavedConsensusSample(t *testing.T) {
	_, e := os.Stat(savedIncidentInput())
	if e != nil {
		if os.Getenv("GONKACTL_TRACE_REQUIRE_SAMPLE") == "1" {
			t.Fatal(e)
		}
		t.Skip("run make qualify with retained sample")
	}
	c, _, _, _, e := loadPerfettoInput(savedIncidentInput())
	if e != nil {
		t.Fatal(e)
	}
	before, ok := c.height(306552).set("")
	if !ok || before.Total != 405 || quorum(before.Total) != 271 {
		t.Fatal(before)
	}
	after, ok := c.height(306553).set("")
	if !ok || after.Total != 135 {
		t.Fatal(after)
	}
	if c.height(306553).Rounds[1] {
		t.Fatal("false R1")
	}
	changed := c.changes(306553)
	count := 0
	for _, v := range changed {
		if v.OldPower != v.NewPower {
			count++
			if !v.UpdateMatches {
				t.Fatal(v)
			}
		}
	}
	if count != 4 {
		t.Fatal(changed)
	}
	stale := 0
	historicalSigners := 0
	target := ""
	for _, o := range c.height(306553).Observations {
		if o.Kind == "timer.stale" {
			stale++
		}
		if o.Kind == "signer.signed" && o.Phase == "PREVOTE" {
			historicalSigners++
			target = o.Target
			if len(o.Validator) != 40 {
				t.Fatal("unknown actual signer", o)
			}
		}
	}
	if stale == 0 || historicalSigners != 2 || strings.HasPrefix(target, "unknown") {
		t.Fatal(stale, historicalSigners, target)
	}
	tally := c.tally(306553, 0, "PREVOTE", target, "snapshot", "node1", "")
	if tally.Power != 81 || tally.Quorum != 91 || tally.Deficit != 10 {
		t.Fatal(tally)
	}
	if c.tally(306553, 0, "PRECOMMIT", "any", "historical-union", "", "").Power != 0 {
		t.Fatal("false precommit")
	}
	header := c.height(306552).HeaderTime
	found := false
	for _, o := range c.height(306552).Observations {
		if o.Kind == "commit.finalizing" && o.Observer == "node0" {
			found = true
			if !o.Time.After(header.Add(5 * time.Second)) {
				t.Fatal("header time confused with commit")
			}
		}
	}
	if !found {
		t.Fatal("missing finalizing commit")
	}
	tr, e := consensusTrace(c, 0, "")
	if e != nil {
		t.Fatal(e)
	}
	again, e := consensusTrace(c, 0, "")
	if e != nil {
		t.Fatal(e)
	}
	firstJSON, e := marshalTrace(tr)
	if e != nil {
		t.Fatal(e)
	}
	againJSON, e := marshalTrace(again)
	if e != nil || string(firstJSON) != string(againJSON) {
		t.Fatal("nondeterministic consensus export", e)
	}
	replayed, e := consensusTrace(c, time.Hour, "new")
	if e != nil {
		t.Fatal(e)
	}
	a := tr.ResourceSpans().At(0).ScopeSpans().At(0).Spans()
	r := replayed.ResourceSpans().At(0).ScopeSpans().At(0).Spans()
	if a.Len() > 1000 {
		t.Fatal("not compact", a.Len())
	}
	for i := 0; i < a.Len(); i++ {
		if r.At(i).StartTimestamp().AsTime().Sub(a.At(i).StartTimestamp().AsTime()) != time.Hour {
			t.Fatal("unequal replay shift")
		}
		if r.At(i).TraceID() == a.At(i).TraceID() {
			t.Fatal("replay identity reused")
		}
	}
}
