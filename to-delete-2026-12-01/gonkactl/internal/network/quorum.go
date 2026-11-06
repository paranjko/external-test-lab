package network

import (
	"fmt"
	"sort"
)

type RuntimeTuple struct{ Core, DAPI string }
type Observation struct {
	NodeID, RemoteIP, Root, Core, DAPI, Lineage string
	Usable                                      bool
}

func SelectRuntime(observations []Observation, chainID string) (RuntimeTuple, error) {
	q := 3
	if chainID == "gonka-devnet-community" {
		q = 2
	}
	nodes, ips := map[string]Observation{}, map[string]string{}
	for _, o := range observations {
		if !o.Usable {
			continue
		}
		if prior, ok := nodes[o.NodeID]; ok && (prior.RemoteIP != o.RemoteIP || prior.Core != o.Core || prior.DAPI != o.DAPI) {
			return RuntimeTuple{}, fmt.Errorf("identity conflict")
		}
		if id, ok := ips[o.RemoteIP]; ok && id != o.NodeID {
			return RuntimeTuple{}, fmt.Errorf("IP collision")
		}
		nodes[o.NodeID] = o
		ips[o.RemoteIP] = o.NodeID
	}
	if len(nodes) < q {
		return RuntimeTuple{}, fmt.Errorf("insufficient quorum")
	}
	dapi := map[string]int{}
	for _, o := range nodes {
		dapi[o.DAPI]++
	}
	winner, count := strictWinner(dapi, len(nodes))
	if count == 0 {
		return RuntimeTuple{}, fmt.Errorf("no strict DAPI majority")
	}
	core := map[string]int{}
	roots := map[string]bool{}
	for _, o := range nodes {
		if o.DAPI == winner {
			core[o.Core]++
			roots[o.Root] = true
		}
	}
	coreWinner, coreCount := strictWinner(core, count)
	if coreCount < q || len(roots) < 2 {
		return RuntimeTuple{}, fmt.Errorf("insufficient tuple support")
	}
	return RuntimeTuple{Core: coreWinner, DAPI: winner}, nil
}
func strictWinner(values map[string]int, total int) (string, int) {
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	best, n := "", 0
	for _, k := range keys {
		if values[k] > n {
			best, n = k, values[k]
		}
	}
	if n*2 <= total {
		return "", 0
	}
	return best, n
}

func ValidateLineage(values []string) error {
	counts := map[string]int{}
	for _, v := range values {
		if v != "" {
			counts[v]++
		}
	}
	if len(counts) != 2 {
		return fmt.Errorf("lineage requires one outlier")
	}
	for _, n := range counts {
		if n == 2 {
			return nil
		}
	}
	return fmt.Errorf("lineage quorum conflict")
}
