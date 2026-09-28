package main

import (
	"fmt"
	"sort"
	"strings"
)

// Only explicit local state transitions bound state slices. Timer expiry,
// signatures, RPC collection, and absence of messages never advance a state.
func (a *PFAnalysis) buildIntervalsAndMetrics(c ConsensusTimeline) {
	es := append([]PFEvent(nil), a.Events...)
	sort.SliceStable(es, func(i, j int) bool { return timestamp(es[i].OccurredAt).Before(timestamp(es[j].OccurredAt)) })
	states, applications := map[string]PFEvent{}, map[string]PFEvent{}
	addInterval := func(first, last PFEvent, actor, phase, basis string) {
		start, end := timestamp(first.OccurredAt), timestamp(last.OccurredAt)
		if !end.After(start) {
			return
		}
		id := pfID("interval", first.ID, last.ID)
		refs := unique(append(append([]string{}, first.SourceRefs...), last.SourceRefs...))
		a.Intervals = append(a.Intervals, PFInterval{ID: id, ActorID: actor, Height: first.Height, Round: first.Round, Phase: phase, StartNS: first.TraceNS, EndNS: last.TraceNS, FromEvent: first.ID, ToEvent: last.ID, Basis: basis, SourceRefs: refs})
		a.Measurements = append(a.Measurements, PFMeasurement{ID: pfID(id, "duration"), Metric: "consensus.phase_duration", Value: intp(end.Sub(start).Nanoseconds()), Unit: "ns", Height: first.Height, Round: first.Round, Type: phase, Observer: first.ObserverID, Basis: basis, Temporality: "historical", IdentityBasis: "not applicable", SourceRefs: refs, AsOf: last.OccurredAt, Coverage: "bounded by two local records; intermediate coverage not established"})
	}
	for _, e := range es {
		if e.OccurredAt == "" || e.Temporality != "historical" {
			continue
		}
		key := fmt.Sprintf("%s/%d/%d", e.ActorID, e.Height, e.Round)
		if strings.HasPrefix(e.Kind, "state.") {
			if prev, ok := states[key]; ok && phaseRank(e.Phase) > phaseRank(prev.Phase) {
				addInterval(prev, e, strings.Replace(e.ActorID, "core@", "state@", 1), prev.Phase, "reconstructed from explicit local transitions")
			}
			if prev, ok := states[key]; !ok || phaseRank(e.Phase) > phaseRank(prev.Phase) {
				states[key] = e
			}
		}
		appKey := fmt.Sprintf("%s/%d", e.ActorID, e.Height)
		if e.Kind == "commit.finalizing" {
			applications[appKey] = e
		}
		if e.Kind == "application.executed" {
			if prev, ok := applications[appKey]; ok {
				addInterval(prev, e, strings.Replace(e.ActorID, "core@", "application@", 1), "APPLICATION", "local finalizing-to-execution window; not FinalizeBlock duration")
				delete(applications, appKey)
			}
		}
		if e.Kind == "application.error" {
			a.Findings = append(a.Findings, fmt.Sprintf("H%d %s: application failure observed after/while processing; inspect certificate separately from quorum deficit", e.Height, e.ObserverID))
		}
	}
	for _, hn := range c.orderedHeights() {
		if hn < c.From || hn > c.To+1 {
			continue
		}
		h := c.height(hn)
		base := PFMeasurement{Height: hn, Round: -1, Unit: "count", Basis: "retained records", Temporality: "historical", IdentityBasis: "not applicable", Coverage: "source-limited; absence is not proof of zero"}
		observerRounds := map[string]map[int64]bool{}
		for _, o := range h.Observations {
			if o.Round >= 0 && o.Phase != "HEADER" && o.Phase != "APPLICATION" && o.Phase != "IDENTITY" {
				if observerRounds[o.Observer] == nil {
					observerRounds[o.Observer] = map[int64]bool{}
				}
				observerRounds[o.Observer][o.Round] = true
			}
		}
		for _, observer := range sortedKeys(observerRounds) {
			m := base
			m.ID = pfID("round-count", fmt.Sprint(hn), observer)
			m.Metric = "consensus.rounds_observed"
			m.Observer = observer
			m.Value = intp(int64(len(observerRounds[observer])))
			a.Measurements = append(a.Measurements, m)
		}
		prev := c.Heights[hn-1]
		if prev != nil && !prev.HeaderTime.IsZero() && !h.HeaderTime.IsZero() {
			m := base
			m.ID = pfID("block-interval", fmt.Sprint(hn))
			m.Metric = "consensus.block_interval"
			m.Unit = "ns"
			m.Basis = "adjacent retained block header timestamps"
			m.Value = intp(h.HeaderTime.Sub(prev.HeaderTime).Nanoseconds())
			a.Measurements = append(a.Measurements, m)
		}
	}
	for _, change := range a.Changes {
		for _, metric := range []string{"membership.power", "membership.activation_distance"} {
			value, unit := change.NewPower, "power"
			if metric == "membership.activation_distance" {
				value, unit = change.Distance, "blocks"
			}
			a.Measurements = append(a.Measurements, PFMeasurement{ID: pfID(change.ID, metric), Metric: metric, Value: value, Unit: unit, Height: change.Height, Round: -1, Target: change.ValidatorID, Basis: change.Stage, Temporality: "height-indexed", IdentityBasis: "observed", SourceRefs: change.SourceRefs, Coverage: "membership records; no wall-clock activation inferred"})
		}
	}
	// Missing instrumentation remains null, never a successful zero count.
	for _, metric := range []string{"signer.errors", "process.restarts", "coverage.continuous_interval_count"} {
		a.Measurements = append(a.Measurements, PFMeasurement{ID: pfID("unavailable", metric), Metric: metric, Unit: "count", Height: a.Meta.FocusHeight, Round: -1, Basis: "unavailable", Temporality: "unknown", IdentityBasis: "unknown", Coverage: "not established by supported retained records"})
	}
}
