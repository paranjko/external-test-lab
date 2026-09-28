package main

import "fmt"

type HeightRange struct {
	From int64 `json:"from"`
	To   int64 `json:"to"`
}

func includesHeight(ranges []HeightRange, h int64) bool {
	if len(ranges) == 0 {
		return true
	}
	for _, r := range ranges {
		if h >= r.From && h <= r.To {
			return true
		}
	}
	return false
}

// Explicit selections support a long historical range without pretending all
// intermediate blocks were collected. Original request receipts remain authoritative.
type HistoryRequest struct {
	Node   string `json:"node"`
	Method string `json:"method"`
	Height int64  `json:"height"`
}

func validateHistory(c Config, from, to int64) error {
	for _, r := range c.LogDetailRanges {
		if r.From < from || r.To > to+1 || r.To < r.From {
			return fmt.Errorf("log detail range outside declared range")
		}
	}
	if len(c.History) > 16000 {
		return fmt.Errorf("history selection exceeds 16000 requests")
	}
	nodes := map[string]bool{}
	for _, n := range c.Nodes {
		nodes[n.ID] = true
	}
	seen := map[string]bool{}
	for _, r := range c.History {
		if !nodes[r.Node] || r.Height < from || r.Height > to+1 {
			return fmt.Errorf("history request outside declared nodes/range")
		}
		switch r.Method {
		case "block", "block_results", "commit", "validators":
		default:
			return fmt.Errorf("unsupported history method")
		}
		key := fmt.Sprintf("%s/%s/%d", r.Node, r.Method, r.Height)
		if seen[key] {
			return fmt.Errorf("duplicate history request")
		}
		seen[key] = true
	}
	return nil
}
