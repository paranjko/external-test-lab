package main

// A read-only presentation subset of the retained analysis, not a new analysis
// or a complete replay. No observations are resampled within these heights.
type PFMatrix struct {
	Application  *ApplicationReport `json:"application,omitempty"`
	Meta         PFMeta             `json:"meta"`
	From         int64              `json:"from"`
	To           int64              `json:"to"`
	Actors       []PFActor          `json:"actors"`
	Events       []PFEvent          `json:"events"`
	Observations []PFObservation    `json:"observations"`
	Sets         []PFSet            `json:"validator_sets"`
	Bindings     []PFBinding        `json:"bindings"`
	Findings     []string           `json:"findings"`
	Coverage     []string           `json:"coverage"`
	Changes      []PFChange         `json:"membership_changes"`
	Certificates []PFCertificate    `json:"certificates"`
	PriorSets    []PFSet            `json:"prior_identity_sets"`
}

func matrixSubset(a PFAnalysis) PFMatrix {
	m := PFMatrix{Meta: a.Meta, From: 306550, To: 306553, Actors: a.Actors, Findings: a.Findings, Coverage: a.Coverage}
	if a.Meta.FocusHeight > 0 {
		m.To = a.Meta.FocusHeight
		m.From = m.To - 3
		if a.Meta.From > m.From {
			m.From = a.Meta.From
		}
		if m.From < 1 {
			m.From = 1
		}
	}
	m.Application = a.Application
	inRange := func(h int64) bool { return h >= m.From && h <= m.To }
	ids, bindings := map[string]bool{}, map[string]bool{}
	refs := map[string]bool{}
	for _, c := range a.Changes {
		if inRange(c.Height) {
			m.Changes = append(m.Changes, c)
		}
	}
	for _, c := range a.Certificates {
		if inRange(c.Height) {
			m.Certificates = append(m.Certificates, c)
			for _, ref := range c.SourceRefs {
				refs[ref] = true
			}
		}
	}
	// First retained positive-power sample for each named historical identity.
	// This is not a registration timestamp or a proof of continuous membership.
	first := map[string]PFSet{}
	for _, actor := range a.Actors {
		if actor.Kind == "consensus_identity" && actor.Participant != "" {
			for _, s := range a.Sets {
				if s.Height >= m.From {
					continue
				}
				for _, v := range s.Validators {
					if v.Address == actor.ID && v.Power > 0 {
						if old, ok := first[actor.ID]; !ok || s.Height < old.Height {
							first[actor.ID] = s
						}
					}
				}
			}
		}
	}
	seenHeights := map[int64]bool{}
	for _, actor := range a.Actors {
		if s, ok := first[actor.ID]; ok && !seenHeights[s.Height] {
			m.PriorSets = append(m.PriorSets, s)
			seenHeights[s.Height] = true
		}
	}
	for _, e := range a.Events {
		if inRange(e.Height) || (e.Kind == "validator.jailed.liveness" && e.Height <= m.To) {
			m.Events = append(m.Events, e)
			ids[e.ID] = true
			for _, id := range e.BindingIDs {
				bindings[id] = true
			}
		}
	}
	for _, o := range a.Observations {
		if ids[o.EventID] || refs[o.ID] {
			m.Observations = append(m.Observations, o)
		}
	}
	for _, s := range a.Sets {
		if inRange(s.Height) {
			m.Sets = append(m.Sets, s)
		}
	}
	for _, b := range a.Bindings {
		if bindings[b.ID] {
			m.Bindings = append(m.Bindings, b)
		}
	}
	return m
}
