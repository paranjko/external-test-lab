package main

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"time"
)

var votesRE = regexp.MustCompile(`BA\{(\d+):([_x]+)\}\s*(\d+)/(\d+)`)

func voteMetrics(e Event, sets map[string]int64) map[string]any {
	result := map[string]any{"node": e.Node, "height": e.Height, "round": e.Round, "type": e.Type, "source": e.Source, "status": "unknown", "current_observation": e.Current}
	m := votesRE.FindStringSubmatch(e.Attr["votes.bit_array"])
	if len(m) == 0 {
		return result
	}
	n, _ := strconv.Atoi(m[1])
	v, t := number(m[3]), number(m[4])
	if t <= 0 || v < 0 || v > t {
		return result
	}
	q := 2*(t/3) + (2*(t%3))/3 + 1
	deficit := q - v
	if deficit < 0 {
		deficit = 0
	}
	result["observed_power"] = v
	result["total_power"] = t
	result["quorum"] = q
	result["deficit"] = deficit
	result["status"] = "partial"
	result["scope"] = "recorded round votes across targets, not a same-block quorum certificate"
	if n == len(m[2]) && sets[fmt.Sprintf("%s/%d", e.Node, e.Height)] == t {
		result["status"] = "complete_snapshot"
	}
	return result
}
func summarize(d Dataset) map[string]any {
	sets := map[string]int64{}
	for _, e := range d.Events {
		if e.Type == "validators.set" {
			sets[fmt.Sprintf("%s/%d", e.Node, e.Height)] = number(e.Attr["voting_power.total"])
		}
	}
	votes := []map[string]any{}
	counts := map[string]int{}
	rounds := map[string]map[int64]bool{}
	timeouts := map[string]int{}
	blocks := map[int64]time.Time{}
	joins := map[string]Event{}
	delays := []map[string]any{}
	for _, e := range d.Events {
		counts[e.Node+"/"+e.Type]++
		if e.Type == "consensus.timeout" {
			timeouts[fmt.Sprintf("%s/%d", e.Node, e.Height)]++
		}
		if e.Round != nil {
			k := fmt.Sprintf("%s/%d", e.Node, e.Height)
			if rounds[k] == nil {
				rounds[k] = map[int64]bool{}
			}
			rounds[k][*e.Round] = true
		}
		if _, ok := e.Attr["votes.bit_array"]; ok {
			votes = append(votes, voteMetrics(e, sets))
		}
		if e.Type == "block.commit" && e.Component == "cometbft" && !e.Inferred && !e.Current {
			blocks[e.Height] = e.Time
		}
		id := e.Attr["operation_id"]
		if id == "" {
			id = e.Attr["run_id"]
		}
		if id != "" {
			key := e.Node + "/" + id
			if e.Type == "join.register" {
				joins[key] = e
			}
			if j, ok := joins[key]; ok && (e.Type == "consensus.prevote" || e.Type == "consensus.precommit") && !e.Time.Before(j.Time) {
				delays = append(delays, map[string]any{"node": e.Node, "operation": id, "seconds": e.Time.Sub(j.Time).Seconds(), "basis": "same explicit operation/run ID", "from": j.Source, "to": e.Source})
				delete(joins, key)
			}
		}
	}
	hs := []int64{}
	for h := range blocks {
		hs = append(hs, h)
	}
	sort.Slice(hs, func(i, j int) bool { return hs[i] < hs[j] })
	intervals := []map[string]any{}
	for i := 1; i < len(hs); i++ {
		if hs[i] == hs[i-1]+1 {
			intervals = append(intervals, map[string]any{"height": hs[i], "seconds": blocks[hs[i]].Sub(blocks[hs[i-1]]).Seconds()})
		}
	}
	gaps := []Receipt{}
	coverage := map[string]int{}
	for _, r := range d.Receipts {
		if r.Error != "" {
			gaps = append(gaps, r)
		} else {
			coverage[r.Node]++
		}
	}
	roundCounts := map[string]int{}
	for k, r := range rounds {
		roundCounts[k] = len(r)
	}
	return map[string]any{"incident": d.Config.Incident, "range": []int64{d.From, d.To}, "collected_at": d.Collected, "header_window": []time.Time{d.Start, d.End}, "events": len(d.Events), "successful_sources_by_node": coverage, "gaps": gaps, "observed_event_counts": counts, "observed_round_counts": roundCounts, "observed_timeouts_by_node_height": timeouts, "voting_power": votes, "block_intervals": intervals, "join_consensus_delays": delays, "limitations": []string{"Counts are observed records, not complete activity; missing logs are not zero", "Signer starts are not proven process restarts", "Current round snapshots are not historical round archives or fresh signer availability", "JOIN delays require an explicit shared run/operation ID; absent entries mean unknown", "RPC data are observations, not independently verified cryptographic proofs"}}
}
