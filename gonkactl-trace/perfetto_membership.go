package main

import (
	"fmt"
	"time"
)

// Discrete samples at block-header anchors, not exact wall-clock activation.
// Missing/inconsistent sets remain gaps; no zero is emitted for unknown membership.
func (a *PFAnalysis) buildMembershipSeries(c ConsensusTimeline) {
	earliest := map[int64]time.Time{}
	for _, e := range a.Events {
		if e.Temporality == "historical" && e.OccurredAt != "" {
			t := timestamp(e.OccurredAt)
			if old := earliest[e.Height]; old.IsZero() || t.Before(old) {
				earliest[e.Height] = t
			}
		}
	}
	ids := map[string]bool{}
	for _, set := range a.Sets {
		for _, v := range set.Validators {
			ids[v.Address] = true
		}
	}
	for _, set := range a.Sets {
		if !set.Complete || set.Total == nil {
			continue
		}
		anchor := c.height(set.Height).HeaderTime
		basis := "complete V(H); block header time anchor, not activation timestamp"
		if anchor.IsZero() {
			anchor = earliest[set.Height]
			basis = "complete V(H); earliest retained event at H anchors sample, not activation timestamp"
		}
		if anchor.IsZero() || anchor.Before(c.Start) {
			continue
		}
		powers := map[string]int64{"total": *set.Total, "quorum": *set.Quorum}
		for id := range ids {
			powers[id] = 0
		}
		for _, v := range set.Validators {
			powers[v.Address] = v.Power
		}
		for _, id := range sortedKeys(powers) {
			a.Measurements = append(a.Measurements, PFMeasurement{ID: pfID("active-power", fmt.Sprint(set.Height), id), Metric: "membership.active_power",
				Value: intp(powers[id]), Unit: "power", Height: set.Height, Round: -1, Target: id, Basis: basis,
				Temporality: "historical", IdentityBasis: "complete validator set", MembershipComplete: true,
				SourceRefs: set.SourceRefs, AsOf: iso(anchor), TraceNS: fmt.Sprint(anchor.Sub(c.Start).Nanoseconds()),
				Coverage: "discrete height samples; no interpolation across missing heights; not signer availability"})
		}
	}
}
