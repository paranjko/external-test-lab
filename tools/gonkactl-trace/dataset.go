package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Reapply current normalization rules to retained sources, without recollecting.
func rebuildEvents(d *Dataset) error {
	d.Events = nil
	type validatorPages struct {
		height, total int64
		node          string
		values        []map[string]any
		refs          []string
		valid         bool
		pages         map[int64]bool
	}
	sets := map[string]*validatorPages{}
	for _, r := range d.Receipts {
		if r.Application != nil {
			continue
		}
		if !strings.HasPrefix(r.Source, "http") {
			continue
		}
		if r.Error != "" {
			continue
		}
		b, err := readReceipt(r)
		if err != nil {
			return err
		}
		var result rpcResult
		if err = json.Unmarshal(b, &result); err != nil {
			return err
		}
		u, err := url.Parse(r.Source)
		if err != nil {
			return err
		}
		method := path.Base(u.Path)
		h := number(u.Query().Get("height"))
		d.Events = append(d.Events, normalizeRPC(method, result.Result, r.Node, h, r.Path, r.Collected)...)
		if method == "validators" {
			var v struct {
				Validators []map[string]any `json:"validators"`
				Total      string           `json:"total"`
				Height     string           `json:"block_height"`
			}
			if json.Unmarshal(result.Result, &v) != nil {
				continue
			}
			key := fmt.Sprintf("%s/%d", r.Node, h)
			s := sets[key]
			if s == nil {
				s = &validatorPages{node: r.Node, height: h, total: number(v.Total), valid: true, pages: map[int64]bool{}}
				sets[key] = s
			}
			page := number(u.Query().Get("page"))
			if s.total != number(v.Total) || number(v.Height) != h || s.pages[page] || page < 1 {
				s.valid = false
			}
			s.pages[page] = true
			s.values = append(s.values, v.Validators...)
			s.refs = append(s.refs, r.Path)
		}
	}
	for _, s := range sets {
		if !s.valid || int64(len(s.values)) != s.total {
			continue
		}
		seen := map[string]bool{}
		var total int64
		for _, v := range s.values {
			a := str(v["address"])
			p, e := strconv.ParseInt(str(v["voting_power"]), 10, 64)
			if e != nil || p < 0 || p > 1<<50 || a == "" || seen[a] {
				s.valid = false
				break
			}
			seen[a] = true
			total += p
		}
		if !s.valid {
			continue
		}
		sort.Strings(s.refs)
		d.Events = append(d.Events, Event{Node: s.node, Component: "cometbft", Height: s.height, Type: "validators.set", Source: strings.Join(s.refs, ","), Attr: map[string]string{"voting_power.total": strconv.FormatInt(total, 10), "validators.complete": "true", "validators.count": strconv.Itoa(len(s.values))}})
	}
	d.Start = time.Time{}
	d.End = time.Time{}
	for _, e := range d.Events {
		if e.Type == "block.commit" && !e.Time.IsZero() {
			if d.Start.IsZero() || e.Time.Before(d.Start) {
				d.Start = e.Time
			}
			if e.Time.After(d.End) {
				d.End = e.Time
			}
		}
	}
	pad := time.Duration(d.Config.PaddingSeconds) * time.Second
	for _, r := range d.Receipts {
		if strings.HasPrefix(r.Source, "http") {
			continue
		}
		// A timed-out log command can retain useful complete records before the
		// interruption. Preserve those records and keep its receipt error as a gap.
		if r.Bytes == 0 {
			continue
		}
		if r.Error != "" && !strings.Contains(r.Error, "truncated") && !(strings.HasPrefix(r.Source, "docker:") && r.Error == "signal: killed") {
			continue
		}
		b, err := readReceipt(r)
		if err != nil {
			return err
		}
		component := "log"
		for _, n := range d.Config.Nodes {
			if n.ID == r.Node {
				for _, s := range n.Logs {
					if s.Kind+":"+s.Path == r.Source {
						component = s.Component
					}
				}
			}
		}
		events := normalizeLog(string(b), r.Node, component, r.Path, d.From, d.To, d.Start.Add(-pad), d.End.Add(pad), !d.Start.IsZero())
		for i := range events {
			annotateProcess(&events[i], r)
		}
		d.Events = append(d.Events, events...)
	}
	inferTimes(d)
	return nil
}
func readReceipt(r Receipt) ([]byte, error) {
	p := filepath.Clean(r.Path)
	if r.localPath != "" {
		p = r.localPath
	}
	if r.localPath == "" && (filepath.IsAbs(p) || !strings.HasPrefix(p, datasetDir+string(os.PathSeparator))) {
		return nil, fmt.Errorf("receipt outside dataset: %s", p)
	}
	info, e := os.Lstat(p)
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() || info.Size() > maxSourceBytes {
		return nil, fmt.Errorf("unsafe or oversized receipt %s", p)
	}
	return os.ReadFile(p)
}
