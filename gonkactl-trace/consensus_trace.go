package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

func jsonText(v any) string { b, _ := json.Marshal(v); return string(b) }
func short(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}
func (c *ConsensusTimeline) heightBounds(h *ConsensusHeight) (time.Time, time.Time) {
	a, b := h.HeaderTime, h.HeaderTime
	for _, o := range h.Observations {
		if o.DisplayOnly || o.Time.IsZero() {
			continue
		}
		if a.IsZero() || o.Time.Before(a) {
			a = o.Time
		}
		if o.Time.After(b) {
			b = o.Time
		}
	}
	if a.IsZero() {
		a = c.Start
	}
	if b.IsZero() {
		b = a
	}
	if h.Height > c.To {
		b = c.End
	}
	if b.Before(a) {
		b = a
	}
	return a, b.Add(time.Millisecond)
}
func consensusTrace(c ConsensusTimeline, shift time.Duration, replayID string) (ptrace.Traces, error) {
	t := ptrace.NewTraces()
	if len(c.Heights) == 0 || c.Start.IsZero() {
		return t, fmt.Errorf("no historically anchored consensus data")
	}
	seed := c.Incident + "/consensus/" + c.Collected.Format(time.RFC3339Nano) + "/" + replayID
	tid := traceID(seed)
	rs := t.ResourceSpans().AppendEmpty()
	attrs(rs.Resource().Attributes(), map[string]string{"service.name": "gonkactl-trace-consensus", "trace.view": "consensus", "incident.id": c.Incident, "chain.id": c.Chain, "protocol.version": "CometBFT v0.38.21"})
	ss := rs.ScopeSpans().AppendEmpty()
	ss.Scope().SetName("gonkactl-trace/consensus")
	spans := ss.Spans()
	counter := 0
	add := func(name string, parent pcommon.SpanID, a, b time.Time, values map[string]string) ptrace.Span {
		if a.IsZero() {
			a = c.Start
		}
		if b.IsZero() || !b.After(a) {
			b = a.Add(time.Millisecond)
		}
		counter++
		s := spans.AppendEmpty()
		s.SetTraceID(tid)
		s.SetSpanID(spanID(fmt.Sprintf("%s/%d", seed, counter)))
		s.SetParentSpanID(parent)
		s.SetName(name)
		s.SetKind(ptrace.SpanKindInternal)
		s.SetStartTimestamp(pcommon.NewTimestampFromTime(a.Add(shift)))
		s.SetEndTimestamp(pcommon.NewTimestampFromTime(b.Add(shift)))
		s.Attributes().PutBool("reconstructed", true)
		attrs(s.Attributes(), map[string]string{"trace.view": "consensus", "original_start": a.Format(time.RFC3339Nano), "original_end": b.Format(time.RFC3339Nano), "grouping": "analytical, not a network call", "node.id": "multiple observers"})
		attrs(s.Attributes(), values)
		if replayID != "" {
			s.Attributes().PutBool("replay", true)
			s.Attributes().PutStr("replay_id", replayID)
		}
		return s
	}
	root := add(c.Incident+" | CONSENSUS", pcommon.SpanID{}, c.Start, c.End.Add(time.Millisecond), map[string]string{"gaps": jsonText(c.Gaps), "window.end.reason": "configured collection window; not end of outage"})
	ordinary := 0
	for _, h := range c.orderedHeights() {
		if h >= c.From && h <= c.To && !c.significant(h) {
			ordinary++
		}
	}
	add(fmt.Sprintf("Overview | %d ordinary heights with retained headers/certificates", ordinary), root.SpanID(), c.Start, c.Start.Add(time.Millisecond), map[string]string{"limitation": "certificate does not reconstruct prevotes, locks or all rounds"})
	for _, hn := range c.orderedHeights() {
		if hn < c.From || hn > c.To+1 || !c.significant(hn) {
			continue
		}
		h := c.height(hn)
		a, b := c.heightBounds(h)
		height := add(fmt.Sprintf("H%d", hn), root.SpanID(), a, b, nil)
		if !h.HeaderTime.IsZero() {
			add("HEADER timestamp | not commit time", height.SpanID(), h.HeaderTime, h.HeaderTime.Add(time.Millisecond), map[string]string{"block.id": h.BlockID, "time.kind": "header timestamp"})
		}
		if s, ok := h.set(""); ok {
			change := c.changes(hn)
			label := fmt.Sprintf("ACTIVE SET | %d validators | T=%d Q=%d", len(s.Validators), s.Total, quorum(s.Total))
			if old, ok := c.height(hn - 1).set(""); ok && old.Total != s.Total {
				label += fmt.Sprintf(" | T %d→%d, Q %d→%d", old.Total, s.Total, quorum(old.Total), quorum(s.Total))
			}
			lane := add(label, height.SpanID(), a, a.Add(time.Millisecond), map[string]string{"validators": jsonText(s.Validators), "source.record": s.Source, "display_only": "true", "membership.time": "effective at this height; display anchor only"})
			for _, v := range change {
				if v.OldPower == v.NewPower {
					continue
				}
				add(fmt.Sprintf("%s %s | power %d→%d | emitted H%d", v.Change, short(v.Address), v.OldPower, v.NewPower, v.Emitted), lane.SpanID(), a, a.Add(time.Millisecond), map[string]string{"validator.address": v.Address, "public_key": v.PublicKey, "source.records": jsonText(v.Sources), "update.matches": fmt.Sprint(v.UpdateMatches), "display_only": "true", "host.binding": "unknown unless separately evidenced"})
			}
		}
		updates := []ConsensusUpdate{}
		seenUpdates := map[string]bool{}
		for _, u := range c.Updates {
			if u.Emitted != hn {
				continue
			}
			key := u.Address + fmt.Sprint(u.Power)
			if !seenUpdates[key] {
				updates = append(updates, u)
				seenUpdates[key] = true
			}
		}
		if len(updates) > 0 {
			add(fmt.Sprintf("ABCI updates | %d identities | effective H%d", len(updates), hn+2), height.SpanID(), a, a.Add(time.Millisecond), map[string]string{"updates": jsonText(updates), "time.kind": "header display anchor, emission wall time unknown", "display_only": "true"})
		}
		for _, o := range h.Observations {
			if o.Phase == "APPLICATION" {
				add(fmt.Sprintf("H%d | %s | %s", hn, o.Kind, o.Observer), height.SpanID(), o.Time, o.Time.Add(time.Millisecond), observationAttrs(o))
			}
		}
		rkeys := []int64{}
		for r := range h.Rounds {
			rkeys = append(rkeys, r)
		}
		sort.Slice(rkeys, func(i, j int) bool { return rkeys[i] < rkeys[j] })
		for _, r := range rkeys {
			round := add(fmt.Sprintf("H%d R%d", hn, r), height.SpanID(), a, b, nil)
			for _, phase := range []string{"NEWHEIGHT", "NEWROUND", "PROPOSE", "PREVOTE", "PREVOTEWAIT", "LOCK", "PRECOMMIT", "PRECOMMITWAIT", "COMMIT", "EXECUTE", "TIMERS"} {
				obs := []ConsensusObservation{}
				var pa, pb time.Time
				for _, o := range h.Observations {
					if o.Round != r || o.Phase != phase || o.DisplayOnly {
						continue
					}
					obs = append(obs, o)
					if !o.Time.IsZero() {
						if pa.IsZero() || o.Time.Before(pa) {
							pa = o.Time
						}
						if o.Time.After(pb) {
							pb = o.Time
						}
					}
				}
				if len(obs) == 0 {
					continue
				}
				endReason := "last_observation"
				if phase == "PREVOTE" && hn > c.To {
					later := false
					for _, o := range h.Observations {
						if o.Round == r && !o.DisplayOnly && (o.Phase == "PRECOMMIT" || o.Phase == "COMMIT") {
							later = true
						}
					}
					if !later {
						pb = c.End
						endReason = "observation_window_end"
					}
				}
				lane := add(fmt.Sprintf("H%d R%d | %s", hn, r, phase), round.SpanID(), pa, pb.Add(time.Millisecond), map[string]string{"end_reason": endReason, "duration.basis": "first/last observed action, not an instrumented phase duration"})
				if phase == "PREVOTE" || phase == "PRECOMMIT" {
					any := c.tally(hn, r, phase, "any", "historical-union", "", "")
					add("ANY targets | "+tallyLabel(any)+" | not a same-block quorum", lane.SpanID(), pa, pa.Add(time.Millisecond), map[string]string{"tally": jsonText(any), "condition": any.Condition})
					for _, point := range c.growth(hn, r, phase) {
						label := "RECEIVED | " + point.Tally.Observer + " | " + short(point.Tally.Target) + " | " + tallyLabel(point.Tally)
						if point.Tally.Complete && point.Tally.Power >= point.Tally.Quorum {
							label += " | threshold reached"
						}
						add(label, lane.SpanID(), point.Time, point.Time.Add(time.Millisecond), map[string]string{"tally": jsonText(point.Tally), "source.record": point.Source, "condition": point.Tally.Condition, "time.kind": "observer-local reception log"})
					}
					targets := map[string]bool{}
					for _, v := range c.Votes {
						if v.Height == hn && v.Round == r && v.Type == phase {
							for _, o := range v.Observations {
								if !o.DisplayOnly {
									targets[v.Target] = true
								}
							}
						}
					}
					tk := []string{}
					for target := range targets {
						tk = append(tk, target)
					}
					sort.Strings(tk)
					for _, target := range tk {
						tally := c.tally(hn, r, phase, target, "historical-union", "", "")
						vspan := add(fmt.Sprintf("%s | %s | union of evidence", short(target), tallyLabel(tally)), lane.SpanID(), pa, pa.Add(time.Millisecond), map[string]string{"tally": jsonText(tally), "condition": tally.Condition, "delivery": "union does not imply quorum reception by any observer"})
						for _, v := range c.Votes {
							if v.Height == hn && v.Round == r && v.Type == phase && v.Target == target {
								historical := []ConsensusObservation{}
								for _, o := range v.Observations {
									if !o.DisplayOnly {
										historical = append(historical, o)
									}
								}
								if len(historical) > 0 {
									first := historical[0]
									power := int64(0)
									for _, s := range tally.Signers {
										if s.Address == v.Validator {
											power = s.Power
										}
									}
									add(fmt.Sprintf("%s | power %d | %d observations", short(v.Validator), power, len(historical)), vspan.SpanID(), first.Time, first.Time.Add(time.Millisecond), map[string]string{"validator.address": v.Validator, "observations": jsonText(historical), "time.kind": first.TimeKind})
								}
							}
						}
					}
				} else {
					for _, o := range obs {
						add(o.Kind+" | "+o.Observer, lane.SpanID(), o.Time, o.Time.Add(time.Millisecond), observationAttrs(o))
					}
				}
			}
			// Certificates are observer-specific evidence of one decision, not vote-delivery timestamps.
			for _, o := range h.Observations {
				if o.Round == r && o.Kind == "commit.certificate" {
					tally := c.tally(hn, r, "PRECOMMIT", o.Target, "certificate", o.Observer, o.Source+"/signatures")
					add(fmt.Sprintf("COMMIT certificate | %s | %s", o.Observer, tallyLabel(tally)), round.SpanID(), a, a.Add(time.Millisecond), map[string]string{"tally": jsonText(tally), "source.record": o.Source, "display_only": "true", "collected_at": o.CollectedAt.Format(time.RFC3339Nano), "condition": tally.Condition})
				}
			}
			// Choose the latest snapshot per observer, but preserve all raw observations in the timeline.
			latest := map[string]ConsensusObservation{}
			for _, o := range h.Observations {
				if o.Round == r && o.Kind == "state.snapshot" {
					old, ok := latest[o.Observer]
					if !ok || o.CollectedAt.After(old.CollectedAt) {
						latest[o.Observer] = o
					}
				}
			}
			nodes := []string{}
			for n := range latest {
				nodes = append(nodes, n)
			}
			sort.Strings(nodes)
			if len(nodes) > 0 {
				snapshot := add("LATER SNAPSHOTS | display-only evidence", round.SpanID(), a, a.Add(time.Millisecond), map[string]string{"display_only": "true", "time.kind": "conditional position; collected_at is real observation time"})
				for _, node := range nodes {
					state := latest[node]
					nodeLane := add(node+" | state "+state.Attributes["round_step"], snapshot.SpanID(), a, a.Add(time.Millisecond), observationAttrs(state))
					for _, phase := range []string{"PREVOTE", "PRECOMMIT"} {
						targets := map[string]bool{}
						prefix := state.Source + "#bucket/"
						for _, v := range c.Votes {
							if v.Height == hn && v.Round == r && v.Type == phase {
								for _, o := range v.Observations {
									if o.Kind == "vote.snapshot" && strings.HasPrefix(o.Source, prefix) {
										targets[v.Target] = true
									}
								}
							}
						}
						targets["any"] = true
						keys := []string{}
						for target := range targets {
							keys = append(keys, target)
						}
						sort.Strings(keys)
						for _, target := range keys {
							tally := c.tally(hn, r, phase, target, "snapshot", node, prefix)
							row := add(fmt.Sprintf("H%d R%d | %s | %s | target %s | snapshot", hn, r, phase, tallyLabel(tally), short(target)), nodeLane.SpanID(), a, a.Add(time.Millisecond), map[string]string{"tally": jsonText(tally), "condition": tally.Condition, "block.id": target, "collected_at": state.CollectedAt.Format(time.RFC3339Nano), "display_only": "true"})
							for _, v := range tally.Signers {
								add(fmt.Sprintf("%s | power %d", short(v.Address), v.Power), row.SpanID(), a, a.Add(time.Millisecond), map[string]string{"validator.address": v.Address, "public_key": v.PublicKey, "display_only": "true"})
							}
							if phase == "PREVOTE" && tally.Complete && tally.Deficit > 0 {
								pc := c.tally(hn, r, "PRECOMMIT", "any", "snapshot", node, prefix)
								add(fmt.Sprintf("Missing %d to prevote quorum | observed precommit power %d", tally.Deficit, pc.Power), row.SpanID(), a, a.Add(time.Millisecond), map[string]string{"missing.validators": jsonText(tally.Missing), "missing.power.in.observation": fmt.Sprint(tally.MissingPower), "not_proven": "offline host or lost private key", "display_only": "true"})
							}
						}
					}
				}
			}
		}
		for _, o := range h.Observations {
			if o.Kind == "identity.historical" {
				add(o.Attributes["host.label"]+" | historical moniker "+short(o.Validator), height.SpanID(), o.Time, o.Time.Add(time.Millisecond), observationAttrs(o))
			}
			if o.Kind == "current.identity" {
				add(o.Observer+" | current identity "+short(o.Validator)+" | historical binding unknown", height.SpanID(), a, a.Add(time.Millisecond), observationAttrs(o))
			}
		}
		if hn > c.To {
			last := "unknown"
			rank := 0
			for _, o := range h.Observations {
				if !o.DisplayOnly && o.Kind != "timer.expired" && o.Kind != "timer.stale" && phaseRank(o.Phase) > rank {
					rank = phaseRank(o.Phase)
					last = o.Phase
				}
			}
			add("Last historical phase: "+last+" | later progress not observed in window", height.SpanID(), b.Add(-time.Millisecond), b, map[string]string{"end_reason": "observation_window_end", "missing.evidence": "continuous received-vote stream / WAL, historic signer identity receipts", "not_proven": "permanent halt, host offline, private-key deletion"})
		}
	}
	return t, nil
}
func observationAttrs(o ConsensusObservation) map[string]string {
	m := map[string]string{"source.record": o.Source, "node.id": o.Observer, "validator.address": o.Validator, "block.id": o.Target, "message": o.Message, "original_timestamp": o.Time.Format(time.RFC3339Nano), "time.kind": o.TimeKind, "display_only": fmt.Sprint(o.DisplayOnly), "inferred": fmt.Sprint(o.Inferred)}
	if !o.CollectedAt.IsZero() {
		m["collected_at"] = o.CollectedAt.Format(time.RFC3339Nano)
	}
	for k, v := range o.Attributes {
		m[k] = v
	}
	return m
}
