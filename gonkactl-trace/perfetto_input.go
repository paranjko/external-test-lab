package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func loadPerfettoInput(input string) (ConsensusTimeline, string, string, string, error) {
	var empty ConsensusTimeline
	if input == "" {
		input = datasetDir + "/latest.json"
	}
	path, err := filepath.Abs(input)
	if err != nil {
		return empty, "", "", "", err
	}
	info, err := os.Stat(path)
	if err != nil {
		return empty, "", "", "", err
	}
	dir := filepath.Dir(path)
	if info.IsDir() {
		dir = path
		path = filepath.Join(dir, "dataset.json")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return empty, "", "", "", err
	}
	var probe map[string]json.RawMessage
	if err = json.Unmarshal(b, &probe); err != nil {
		return empty, "", "", "", err
	}
	fingerprintParts := []string{analyzerVersion, string(b)}
	if _, ok := probe["resourceSpans"]; ok {
		c, e := timelineFromOTLP(b)
		return c, pfID(fingerprintParts...), "otlp", filepath.Join(dir, ".gonka-perfetto", filepath.Base(path)), e
	}
	if _, ok := probe["receipts"]; !ok {
		return empty, "", "", "", fmt.Errorf("unsupported input schema: expected sample dataset or OTLP resourceSpans")
	}
	var d Dataset
	if err = json.Unmarshal(b, &d); err != nil {
		return empty, "", "", "", err
	}
	// Receipt provenance is immutable. Resolve only known filenames within the selected sample.
	sampleDir := dir
	if filepath.Base(path) == "latest.json" && len(d.Receipts) > 0 {
		sampleDir = filepath.Join(dir, filepath.Base(filepath.Dir(d.Receipts[0].Path)))
	}
	gaps := []string{}
	for i := range d.Receipts {
		r := &d.Receipts[i]
		r.localPath = filepath.Join(sampleDir, filepath.Base(r.Path))
		raw, e := readReceipt(*r)
		if e != nil {
			r.Error = "retained source missing or unreadable"
			gaps = append(gaps, r.Path+": "+r.Error)
			fingerprintParts = append(fingerprintParts, r.Path+":missing")
			continue
		}
		fingerprintParts = append(fingerprintParts, r.Path, pfID(string(raw)))
	}
	if err = rebuildEvents(&d); err != nil {
		return empty, "", "", "", err
	}
	c, err := buildConsensus(d)
	c.Gaps = append(c.Gaps, gaps...)
	return c, pfID(fingerprintParts...), "sample", filepath.Join(sampleDir, "derived", "perfetto"), err
}

var pfHR = regexp.MustCompile(`H(\d+)(?: R(\d+))?`)
var pfMembershipLabel = regexp.MustCompile(`^(added|removed|retained) \S+ \| power (\d+)→(\d+) \| emitted H(\d+)$`)

type pfOTLPSpan struct {
	Name       string `json:"name"`
	ID         string `json:"spanId"`
	Parent     string `json:"parentSpanId"`
	Attributes []struct {
		Key   string         `json:"key"`
		Value map[string]any `json:"value"`
	} `json:"attributes"`
}

func timelineFromOTLP(b []byte) (ConsensusTimeline, error) {
	var wire struct {
		Resources []struct {
			Scopes []struct {
				Spans []pfOTLPSpan `json:"spans"`
			} `json:"scopeSpans"`
		} `json:"resourceSpans"`
	}
	if e := json.Unmarshal(b, &wire); e != nil {
		return ConsensusTimeline{}, e
	}
	c := ConsensusTimeline{Heights: map[int64]*ConsensusHeight{}, From: 1 << 62, Incident: "GNK-LAB-2026-0001", Chain: "unknown", Gaps: []string{"OTLP adapter: source excerpts only; original raw files are not loaded"}}
	spans := []pfOTLPSpan{}
	for _, r := range wire.Resources {
		for _, s := range r.Scopes {
			spans = append(spans, s.Spans...)
		}
	}
	index := map[string]pfOTLPSpan{}
	for _, s := range spans {
		index[s.ID] = s
	}
	seen := map[string]bool{}
	context := func(s pfOTLPSpan) (int64, int64) {
		h, r := int64(0), int64(-1)
		for n := 0; n < 20; n++ {
			if m := pfHR.FindStringSubmatch(s.Name); len(m) > 0 {
				h = number(m[1])
				if len(m) > 2 && m[2] != "" {
					r = number(m[2])
				}
				break
			}
			parent, ok := index[s.Parent]
			if !ok {
				break
			}
			s = parent
		}
		return h, r
	}
	for i, s := range spans {
		attrs := map[string]string{}
		for _, a := range s.Attributes {
			for _, v := range a.Value {
				attrs[a.Key] = fmt.Sprint(v)
			}
		}
		h, r := context(s)
		if change := pfMembershipLabel.FindStringSubmatch(s.Name); change != nil && validIdentity(attrs["validator.address"]) {
			// Older OTLP projections carry this fact in a display label. Preserve
			// that provenance without inventing the missing preceding validator set.
			effective, _ := context(index[s.Parent])
			if effective > 0 {
				refs := []string{fmt.Sprintf("otlp:/spans/%d/name (label fallback)", i)}
				var original []string
				_ = json.Unmarshal([]byte(attrs["source.records"]), &original)
				refs = append(refs, original...)
				emitted := number(change[4])
				c.ImportedChanges = append(c.ImportedChanges, PFChange{ID: pfID("membership", fmt.Sprint(effective), attrs["validator.address"]), ValidatorID: attrs["validator.address"], OldPower: intp(number(change[2])), NewPower: intp(number(change[3])), Stage: change[1], Height: effective, Emitted: emitted, Distance: intp(effective - emitted), SourceRefs: refs, UpdateMatches: attrs["update.matches"] == "true"})
			}
		}
		if h > 0 {
			if h < c.From {
				c.From = h
			}
			if h > c.To {
				c.To = h
			}
		}
		source := attrs["source.record"]
		if source == "" {
			source = fmt.Sprintf("otlp:/spans/%d", i)
		}
		if strings.Contains(s.Name, "| CONSENSUS") {
			c.Incident = strings.Split(s.Name, " | ")[0]
			c.Start = timestamp(attrs["original_start"])
			c.End = timestamp(attrs["original_end"])
		}
		if v := attrs["validators"]; v != "" && h > 0 {
			var vs []ConsensusValidator
			if e := json.Unmarshal([]byte(v), &vs); e != nil {
				return c, e
			}
			total := int64(0)
			for _, v := range vs {
				total += v.Power
			}
			c.height(h).Sets["otlp"] = ConsensusSet{Height: h, Observer: "otlp", Source: fmt.Sprintf("otlp:/spans/%d/validators", i), Validators: vs, Total: total, Complete: len(vs) > 0}
		}
		if v := attrs["updates"]; v != "" {
			var us []ConsensusUpdate
			if json.Unmarshal([]byte(v), &us) == nil {
				c.Updates = append(c.Updates, us...)
			}
		}
		if strings.HasPrefix(s.Name, "HEADER") && h > 0 {
			c.height(h).HeaderTime = timestamp(attrs["original_start"])
			c.height(h).BlockID = attrs["block.id"]
		}
		if v := attrs["observations"]; v != "" {
			var observations []ConsensusObservation
			if e := json.Unmarshal([]byte(v), &observations); e != nil {
				return c, e
			}
			for _, o := range observations {
				key := pfID(o.Source, o.Kind, iso(o.Time))
				if !seen[key] {
					if o.Attributes == nil {
						o.Attributes = map[string]string{}
					}
					o.Attributes["otlp.pointer"] = fmt.Sprintf("/spans/%d/observations", i)
					c.add(o)
					seen[key] = true
				}
			}
		}
		if v := attrs["tally"]; v != "" {
			var t ConsensusTally
			if e := json.Unmarshal([]byte(v), &t); e != nil {
				return c, e
			}
			if t.Height <= 0 {
				continue
			}
			if t.Scope == "snapshot" || t.Scope == "certificate" {
				if t.Target == "any" {
					continue
				}
				kind := "vote.snapshot"
				display := true
				voteSource := t.Source
				if t.Scope == "certificate" {
					kind = "vote.certificate"
					display = false
					c.add(ConsensusObservation{Height: t.Height, Round: t.Round, Phase: "COMMIT", Kind: "commit.certificate", Observer: t.Observer, Target: t.Target, Source: strings.TrimSuffix(t.Source, "/signatures"), CollectedAt: timestamp(attrs["collected_at"]), DisplayOnly: true})
				}
				if t.Scope == "snapshot" {
					base := strings.TrimSuffix(t.Source, "#bucket/")
					key := pfID("snapshot", base, t.Observer)
					if !seen[key] {
						c.add(ConsensusObservation{Height: t.Height, Round: t.Round, Phase: "SNAPSHOT", Kind: "state.snapshot", Observer: t.Observer, Source: base, CollectedAt: timestamp(attrs["collected_at"]), DisplayOnly: true, Attributes: map[string]string{"round_step": "unknown", "origin": "otlp tally"}})
						seen[key] = true
					}
				}
				for j, v := range t.Signers {
					o := ConsensusObservation{Height: t.Height, Round: t.Round, Phase: t.Type, Kind: kind, Validator: v.Address, Target: t.Target, Observer: t.Observer, Source: fmt.Sprintf("%s/%d", voteSource, j), CollectedAt: timestamp(attrs["collected_at"]), DisplayOnly: display, TimeKind: "OTLP tally; signature timestamp unavailable"}
					key := pfID(o.Source, o.Kind, o.Target)
					if !seen[key] {
						c.add(o)
						seen[key] = true
					}
				}
			}
		}
		if attrs["message"] != "" && h > 0 {
			kind := strings.Split(s.Name, " | ")[0]
			if strings.HasPrefix(kind, "H") {
				continue
			}
			o := ConsensusObservation{Height: h, Round: r, Kind: kind, Observer: attrs["node.id"], Validator: attrs["validator.address"], Target: attrs["block.id"], Source: source, Message: attrs["message"], Time: timestamp(attrs["original_timestamp"]), CollectedAt: timestamp(attrs["collected_at"]), DisplayOnly: attrs["display_only"] == "true", Inferred: attrs["inferred"] == "true", TimeKind: attrs["time.kind"], Attributes: attrs}
			o.Attributes["context.basis"] = "OTLP label fallback"
			switch {
			case strings.HasPrefix(kind, "proposal"):
				o.Phase = "PROPOSE"
			case kind == "signer.signed":
				o.Phase = "PROPOSE"
			case strings.HasPrefix(kind, "epoch"):
				o.Phase = "APPLICATION"
			case strings.HasPrefix(kind, "commit"):
				o.Phase = "COMMIT"
			case strings.HasPrefix(kind, "timer"):
				o.Phase = "TIMERS"
			case strings.HasPrefix(kind, "application"):
				o.Phase = "EXECUTE"
			case kind == "current.identity":
				o.Phase = "IDENTITY"
			}
			key := pfID(o.Source, o.Kind, iso(o.Time))
			if !seen[key] {
				c.add(o)
				seen[key] = true
			}
		}
	}
	if c.Start.IsZero() || c.From == 1<<62 {
		return c, fmt.Errorf("OTLP does not contain a supported consensus projection")
	}
	// Last height with a retained block, not the largest (potentially unfinished) height.
	last := int64(0)
	for hn, h := range c.Heights {
		if h.BlockID != "" && hn > last {
			last = hn
		}
	}
	if last > 0 {
		c.To = last
	} else {
		c.To--
	}
	for _, h := range c.Heights {
		if s, ok := h.Sets["otlp"]; ok {
			for _, o := range h.Observations {
				s.Observer = o.Observer
				h.Sets[o.Observer] = s
			}
		}
	}
	c.correlate()
	return c, nil
}
