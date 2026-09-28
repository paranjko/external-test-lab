package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

type ConsensusTally struct {
	Height, Round                               int64
	Type, Target, Scope, Observer, Source       string
	Total, Quorum, Power, Deficit, MissingPower int64
	Complete                                    bool
	Signers, Missing                            []ConsensusValidator
	Unknown                                     []string
	Condition                                   string
}

type ConsensusGrowth struct {
	Time   time.Time
	Source string
	Tally  ConsensusTally
}

// Delivery progress uses only observer-local reception records, never signature times.
func (c *ConsensusTimeline) growth(h, r int64, kind string) []ConsensusGrowth {
	var observations []ConsensusObservation
	for _, v := range c.Votes {
		if v.Height != h || v.Round != r || v.Type != kind {
			continue
		}
		for _, o := range v.Observations {
			if o.Kind == "vote.received" && !o.DisplayOnly && !o.Time.IsZero() {
				observations = append(observations, o)
			}
		}
	}
	sort.SliceStable(observations, func(i, j int) bool {
		if observations[i].Time.Equal(observations[j].Time) {
			return observations[i].Source < observations[j].Source
		}
		return observations[i].Time.Before(observations[j].Time)
	})
	partial := *c
	partial.Votes = nil
	var out []ConsensusGrowth
	previous := map[string]int64{}
	for _, o := range observations {
		partial.Votes = append(partial.Votes, ConsensusVote{Height: h, Round: r, Type: kind, Validator: o.Validator, Target: o.Target, Observations: []ConsensusObservation{o}})
		for _, target := range []string{"any", o.Target} {
			tally := partial.tally(h, r, kind, target, "received", o.Observer, "")
			key := o.Observer + "/" + target
			if tally.Power > previous[key] {
				out = append(out, ConsensusGrowth{Time: o.Time, Source: o.Source, Tally: tally})
				previous[key] = tally.Power
			}
		}
	}
	return out
}

func (c *ConsensusTimeline) tally(h, r int64, kind, target, scope, observer, source string) ConsensusTally {
	t := ConsensusTally{Height: h, Round: r, Type: kind, Target: target, Scope: scope, Observer: observer, Source: source}
	set, ok := c.height(h).set(observer)
	t.Complete = ok
	t.Total = set.Total
	if ok {
		t.Quorum = quorum(set.Total)
	}
	identities := map[string]bool{}
	for _, v := range c.Votes {
		if v.Height != h || v.Round != r || v.Type != kind || (target != "any" && v.Target != target) {
			continue
		}
		found := false
		for _, o := range v.Observations {
			if observer != "" && o.Observer != observer {
				continue
			}
			if source != "" && !strings.HasPrefix(o.Source, source) {
				continue
			}
			switch scope {
			case "snapshot":
				found = o.Kind == "vote.snapshot"
			case "certificate":
				found = o.Kind == "vote.certificate"
			case "received":
				found = o.Kind == "vote.received"
			default:
				found = !o.DisplayOnly
			}
			if found {
				break
			}
		}
		if found {
			identities[v.Validator] = true
		}
	}
	for _, v := range set.Validators {
		if identities[v.Address] {
			t.Signers = append(t.Signers, v)
			t.Power += v.Power
			delete(identities, v.Address)
		} else {
			t.Missing = append(t.Missing, v)
			t.MissingPower += v.Power
		}
	}
	for id := range identities {
		t.Unknown = append(t.Unknown, id)
	}
	sort.Strings(t.Unknown)
	t.Deficit = t.Quorum - t.Power
	if t.Deficit < 0 {
		t.Deficit = 0
	}
	switch {
	case !ok:
		t.Condition = "active validator set incomplete or conflicting; quorum unknown"
	case target == "any" && kind == "PREVOTE":
		t.Condition = "+2/3 any prevotes permits PrevoteWait, not a same-target lock"
	case target == "any":
		t.Condition = "+2/3 any precommits permits PrecommitWait, not commit"
	case strings.HasPrefix(target, "unknown") || target == "":
		t.Condition = "target unresolved; same-BlockID quorum not established"
	case kind == "PREVOTE":
		t.Condition = "+2/3 prevotes for one target permits Precommit; nil does not lock a block"
	case target == "nil":
		t.Condition = "nil precommits cannot commit a block"
	default:
		t.Condition = "commit requires +2/3 precommits for this non-nil BlockID"
	}
	return t
}

type ConsensusSetChange struct {
	Height, Emitted            int64
	Address, PublicKey, Change string
	OldPower, NewPower         int64
	UpdateMatches              bool
	Sources                    []string
}

func (c *ConsensusTimeline) changes(h int64) []ConsensusSetChange {
	before, ok1 := c.height(h - 1).set("")
	after, ok2 := c.height(h).set("")
	if !ok1 || !ok2 {
		return nil
	}
	old, new := map[string]ConsensusValidator{}, map[string]ConsensusValidator{}
	for _, v := range before.Validators {
		old[v.Address] = v
	}
	for _, v := range after.Validators {
		new[v.Address] = v
	}
	ids := map[string]bool{}
	for id := range old {
		ids[id] = true
	}
	for id := range new {
		ids[id] = true
	}
	keys := []string{}
	for id := range ids {
		keys = append(keys, id)
	}
	sort.Strings(keys)
	out := []ConsensusSetChange{}
	for _, id := range keys {
		a, b := old[id], new[id]
		change := "retained"
		if a.Address == "" {
			change = "added"
		}
		if b.Address == "" {
			change = "removed"
		}
		key := b.PublicKey
		if key == "" {
			key = a.PublicKey
		}
		d := ConsensusSetChange{Height: h, Emitted: h - 2, Address: id, PublicKey: key, OldPower: a.Power, NewPower: b.Power, Change: change, Sources: []string{before.Source, after.Source}}
		if a.Power == b.Power {
			d.UpdateMatches = true
		}
		for _, u := range c.Updates {
			if u.Effective == h && u.Address == id {
				d.Sources = append(d.Sources, u.Source)
				if u.Power == b.Power {
					d.UpdateMatches = true
				}
			}
		}
		out = append(out, d)
	}
	return out
}
func (c *ConsensusTimeline) significant(h int64) bool {
	if h >= c.To {
		return true
	}
	for _, u := range c.Updates {
		if u.Emitted == h || u.Effective == h {
			return true
		}
	}
	for _, o := range c.height(h).Observations {
		if o.Kind == "epoch.changed" || o.Kind == "epoch.compute" {
			return true
		}
	}
	return false
}
func tallyLabel(t ConsensusTally) string {
	if !t.Complete {
		return "weight/quorum unknown"
	}
	suffix := ""
	if len(t.Unknown) > 0 {
		suffix = "; unresolved identities"
	}
	return fmt.Sprintf("%d/%d, need %d%s", t.Power, t.Total, t.Quorum, suffix)
}
