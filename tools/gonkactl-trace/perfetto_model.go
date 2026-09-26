package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

const analysisVersion = "gonka.analysis.v1"
const analyzerVersion = "perfetto-7"

type PFActor struct {
	ID          string  `json:"id"`
	Kind        string  `json:"kind"`
	Label       string  `json:"label"`
	ValidatorID *string `json:"validator_id"`
	PublicKey   string  `json:"public_key,omitempty"`
	Participant string  `json:"participant,omitempty"`
	LabelBasis  string  `json:"label_basis,omitempty"`
}
type PFBinding struct {
	ID         string   `json:"id"`
	From       string   `json:"from"`
	To         string   `json:"to"`
	Basis      string   `json:"basis"`
	Height     int64    `json:"height"`
	Round      int64    `json:"round"`
	SourceRefs []string `json:"source_refs"`
	Reason     string   `json:"reason"`
}
type PFEvent struct {
	ID           string   `json:"event_id"`
	Kind         string   `json:"kind"`
	NetworkID    string   `json:"network_id"`
	ActorID      string   `json:"actor_id"`
	ObserverID   string   `json:"observer_id"`
	ValidatorID  *string  `json:"validator_id"`
	Power        *int64   `json:"power"`
	Height       int64    `json:"height"`
	Round        int64    `json:"round"`
	Phase        string   `json:"phase"`
	Target       string   `json:"block_id"`
	OccurredAt   string   `json:"occurred_at,omitempty"`
	TraceNS      string   `json:"trace_ts_ns,omitempty"`
	TimeBasis    string   `json:"time_basis"`
	ClockDomain  string   `json:"clock_domain"`
	Derivation   string   `json:"derivation"`
	Temporality  string   `json:"temporality"`
	Verification string   `json:"verification"`
	BindingIDs   []string `json:"binding_ids"`
	SourceRefs   []string `json:"source_refs"`
	VoteID       string   `json:"vote_id,omitempty"`
}
type PFObservation struct {
	ID                string            `json:"observation_id"`
	EventID           string            `json:"event_id"`
	ObserverID        string            `json:"observer_id"`
	Kind              string            `json:"source_kind"`
	ObservedAt        string            `json:"observed_at,omitempty"`
	CollectedAt       string            `json:"collected_at,omitempty"`
	SourceRef         string            `json:"source_ref"`
	Excerpt           string            `json:"excerpt"`
	OriginalAvailable bool              `json:"original_available"`
	Attributes        map[string]string `json:"attributes,omitempty"`
}
type PFSet struct {
	Height     int64                `json:"height"`
	Total      *int64               `json:"total"`
	Quorum     *int64               `json:"quorum"`
	Complete   bool                 `json:"membership_complete"`
	Validators []ConsensusValidator `json:"validators"`
	SourceRefs []string             `json:"source_refs"`
}
type PFChange struct {
	ID            string   `json:"id"`
	ValidatorID   string   `json:"validator_id"`
	OldPower      *int64   `json:"old_power"`
	NewPower      *int64   `json:"new_power"`
	Stage         string   `json:"stage"`
	Height        int64    `json:"height"`
	Emitted       int64    `json:"emitted_height,omitempty"`
	Distance      *int64   `json:"activation_distance"`
	SourceRefs    []string `json:"source_refs"`
	UpdateMatches bool     `json:"update_matches"`
}
type PFCell struct {
	ValidatorID   *string  `json:"validator_id"`
	ActorID       string   `json:"actor_id,omitempty"`
	Power         *int64   `json:"power"`
	Proposal      []string `json:"proposal"`
	Prevote       []string `json:"prevote"`
	Precommit     []string `json:"precommit"`
	EventIDs      []string `json:"event_ids"`
	IdentityBasis string   `json:"identity_basis"`
}
type PFMeasurement struct {
	ID                  string   `json:"id"`
	Metric              string   `json:"metric"`
	Value               *int64   `json:"value"`
	Unit                string   `json:"unit"`
	Height              int64    `json:"height"`
	Round               int64    `json:"round"`
	Type                string   `json:"type"`
	Target              string   `json:"target"`
	Observer            string   `json:"observer"`
	Basis               string   `json:"measurement_basis"`
	Temporality         string   `json:"temporality"`
	IdentityBasis       string   `json:"identity_basis"`
	MembershipComplete  bool     `json:"membership_complete"`
	ObservationComplete bool     `json:"observation_complete"`
	Unresolved          int      `json:"unresolved_signatures"`
	SourceRefs          []string `json:"source_refs"`
	AsOf                string   `json:"as_of,omitempty"`
	TraceNS             string   `json:"trace_ts_ns,omitempty"`
	Coverage            string   `json:"coverage"`
}
type PFRound struct {
	ID          string    `json:"id"`
	Height      int64     `json:"height"`
	Round       int64     `json:"round"`
	Observer    string    `json:"observer"`
	Basis       string    `json:"measurement_basis"`
	Temporality string    `json:"temporality"`
	Source      string    `json:"source_ref"`
	CollectedAt string    `json:"collected_at,omitempty"`
	State       string    `json:"state"`
	Rows        []PFCell  `json:"rows"`
	Tallies     []PFTally `json:"tallies"`
}
type PFTally struct {
	Type              string `json:"type"`
	Target            string `json:"target"`
	Power             *int64 `json:"power"`
	ObservedOnlyPower *int64 `json:"observed_only_power"`
	Total             *int64 `json:"total"`
	Quorum            *int64 `json:"quorum"`
	Deficit           *int64 `json:"deficit"`
	Unrepresented     *int64 `json:"unrepresented"`
	Unresolved        int    `json:"unresolved"`
	Condition         string `json:"condition"`
	Assessment        string `json:"assessment"`
}
type PFCertificate struct {
	ID           string   `json:"id"`
	Height       int64    `json:"height"`
	Round        int64    `json:"round"`
	BlockID      string   `json:"block_id"`
	Signers      []string `json:"signers"`
	Power        *int64   `json:"power"`
	Quorum       *int64   `json:"quorum"`
	VariantBasis string   `json:"variant_basis"`
	Observers    []string `json:"observers"`
	SourceRefs   []string `json:"source_refs"`
	Verification string   `json:"verification"`
}
type PFMeta struct {
	Schema      string  `json:"schema"`
	Analyzer    string  `json:"analyzer"`
	Fingerprint string  `json:"fingerprint"`
	Incident    string  `json:"incident"`
	Network     string  `json:"network_id"`
	Genesis     *string `json:"genesis_hash"`
	Origin      string  `json:"utc_origin"`
	EndNS       string  `json:"end_ns"`
	FocusHeight int64   `json:"focus_height"`
	From        int64   `json:"from"`
	To          int64   `json:"to"`
	InputKind   string  `json:"input_kind"`
}
type PFAnalysis struct {
	Application  *ApplicationReport `json:"application,omitempty"`
	Meta         PFMeta             `json:"meta"`
	Actors       []PFActor          `json:"actors"`
	Bindings     []PFBinding        `json:"bindings"`
	Events       []PFEvent          `json:"events"`
	Observations []PFObservation    `json:"observations"`
	Sets         []PFSet            `json:"validator_sets"`
	Changes      []PFChange         `json:"membership_changes"`
	Certificates []PFCertificate    `json:"certificates"`
	Rounds       []PFRound          `json:"round_summaries"`
	Measurements []PFMeasurement    `json:"measurements"`
	Coverage     []string           `json:"coverage"`
	Findings     []string           `json:"findings"`
	Presets      []string           `json:"presets"`
	Intervals    []PFInterval       `json:"intervals"`
	Votes        []PFVote           `json:"votes"`
}

type PFVote struct {
	ID          string   `json:"id"`
	Height      int64    `json:"height"`
	Round       int64    `json:"round"`
	Type        string   `json:"type"`
	ValidatorID *string  `json:"validator_id"`
	Target      string   `json:"target"`
	EventIDs    []string `json:"event_ids"`
	SourceRefs  []string `json:"source_refs"`
}

type PFInterval struct {
	ID         string   `json:"id"`
	ActorID    string   `json:"actor_id"`
	Height     int64    `json:"height"`
	Round      int64    `json:"round"`
	Phase      string   `json:"phase"`
	StartNS    string   `json:"start_ns"`
	EndNS      string   `json:"end_ns"`
	FromEvent  string   `json:"from_event"`
	ToEvent    string   `json:"to_event"`
	Basis      string   `json:"basis"`
	SourceRefs []string `json:"source_refs"`
}

func pfID(parts ...string) string {
	h := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(h[:12])
}
func intp(v int64) *int64   { return &v }
func strp(v string) *string { return &v }
func validIdentity(v string) bool {
	if len(v) != 40 {
		return false
	}
	_, e := hex.DecodeString(v)
	return e == nil
}
func iso(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}
func unique(xs []string) []string {
	m := map[string]bool{}
	out := []string{}
	for _, x := range xs {
		if x != "" && !m[x] {
			m[x] = true
			out = append(out, x)
		}
	}
	sort.Strings(out)
	return out
}
func pfBasis(o ConsensusObservation) string {
	switch o.Kind {
	case "signer.signed":
		return "signing"
	case "vote.certificate", "commit.certificate":
		return "commit_certificate"
	case "vote.snapshot", "state.snapshot", "vote.snapshot.summary":
		return "observer_vote_set"
	case "vote.received":
		return "receipt_log"
	}
	return "event"
}

func makeAnalysis(c ConsensusTimeline, fingerprint, inputKind string) PFAnalysis {
	a := PFAnalysis{Meta: PFMeta{Schema: analysisVersion, Analyzer: analyzerVersion, Fingerprint: fingerprint, Incident: c.Incident, Network: c.Chain + "/" + fingerprint, Origin: iso(c.Start), EndNS: fmt.Sprint(c.End.Sub(c.Start).Nanoseconds()), From: c.From, To: c.To, InputKind: inputKind}, Presets: []string{"overview", "round", "membership", "evidence"}, Coverage: append([]string{}, c.Gaps...)}
	actors := map[string]PFActor{}
	actorBindings := map[string]bool{}
	certs := map[string]*PFCertificate{}
	eventIndex := map[string]int{}
	for _, hn := range c.orderedHeights() {
		if hn < c.From || hn > c.To+1 {
			continue
		}
		h := c.height(hn)
		s, complete := h.set("")
		set := PFSet{Height: hn, Complete: complete, Validators: s.Validators, SourceRefs: []string{}}
		for _, v := range h.Sets {
			set.SourceRefs = append(set.SourceRefs, v.Source)
		}
		set.SourceRefs = unique(set.SourceRefs)
		if complete {
			set.Total = intp(s.Total)
			set.Quorum = intp(quorum(s.Total))
		}
		a.Sets = append(a.Sets, set)
		for _, v := range s.Validators {
			actors[v.Address] = PFActor{ID: v.Address, Kind: "consensus_identity", Label: "Validator " + short(v.Address), ValidatorID: strp(v.Address), PublicKey: v.PublicKey}
		}
		if hn == c.From {
			for _, v := range s.Validators {
				a.Changes = append(a.Changes, PFChange{ID: pfID("baseline", v.Address), ValidatorID: v.Address, NewPower: intp(v.Power), Stage: "baseline", Height: hn, SourceRefs: set.SourceRefs})
			}
		}
		for _, d := range c.changes(hn) {
			stage := d.Change
			if d.OldPower != d.NewPower && stage == "retained" {
				stage = "power changed"
			}
			var distance *int64
			if d.UpdateMatches && d.OldPower != d.NewPower {
				distance = intp(hn - d.Emitted)
			}
			a.Changes = append(a.Changes, PFChange{ID: pfID("membership", fmt.Sprint(hn), d.Address), ValidatorID: d.Address, OldPower: intp(d.OldPower), NewPower: intp(d.NewPower), Stage: stage, Height: hn, Emitted: d.Emitted, Distance: distance, SourceRefs: d.Sources, UpdateMatches: d.UpdateMatches})
		}
		for _, o := range h.Observations {
			actors["host/"+o.Observer] = PFActor{ID: "host/" + o.Observer, Kind: "host", Label: o.Observer}
			actor, label, generationBasis := processActor(o, "core")
			if o.Kind == "signer.signed" {
				actor, label, generationBasis = processActor(o, "signer")
			}
			if o.Kind == "current.identity" {
				actor = "rpc-identity@" + o.Observer + "/current-observation"
				label = actor
			}
			if pfBasis(o) == "commit_certificate" || o.Kind == "header.timestamp" {
				actor = "network/blocks"
				label = actor
				if o.Kind == "vote.certificate" && validIdentity(o.Validator) {
					actor, label = o.Validator, "Validator "+short(o.Validator)+" / certificate signatures"
				}
			}
			if o.Phase == "APPLICATION" {
				actor, label, generationBasis = processActor(o, "application")
				if o.Attributes["source.kind"] == "ABCI block_results" {
					actor, label = "network/application", "network/application"
				}
			}
			if validIdentity(actor) {
				v := actors[actor]
				v.ID, v.Kind, v.Label, v.ValidatorID = actor, "consensus_identity", label, strp(actor)
				actors[actor] = v
			} else {
				actors[actor] = PFActor{ID: actor, Kind: strings.Split(actor, "@")[0], Label: label}
			}
			var validator *string
			var power *int64
			if validIdentity(o.Validator) {
				validator = strp(o.Validator)
				for _, v := range s.Validators {
					if v.Address == o.Validator && complete {
						power = intp(v.Power)
					}
				}
			}
			derivation := "observed"
			if o.Inferred && (o.Kind == "signer.signed" || o.Attributes["height.basis"] != "") {
				derivation = "inferred"
			}
			if validator == nil && o.Kind == "signer.signed" {
				derivation = "unresolved"
			}
			temporality := "historical"
			if o.DisplayOnly {
				temporality = "snapshot"
			}
			eventKey := []string{a.Meta.Network, fmt.Sprint(hn, o.Round), o.Phase, o.Kind, o.Validator, o.Target}
			if !validIdentity(o.Validator) || strings.HasPrefix(o.Target, "unknown") || o.Kind != "vote.certificate" {
				eventKey = append(eventKey, o.Source, iso(o.Time))
			}
			eid := pfID(eventKey...)
			oid := pfID("observation", eid, o.Source, o.Observer, iso(o.CollectedAt))
			bindings := []string{}
			if !strings.HasPrefix(actor, "network/") && !validIdentity(actor) {
				bid := pfID("process-host", actor)
				if !actorBindings[bid] {
					a.Bindings = append(a.Bindings, PFBinding{ID: bid, From: actor, To: "host/" + o.Observer, Basis: "source observer", Height: hn, Round: o.Round, SourceRefs: []string{oid}, Reason: generationBasis})
					actorBindings[bid] = true
				}
				bindings = append(bindings, bid)
			}
			if validator != nil && (o.Kind == "identity.historical" || o.Kind == "current.identity") {
				from := actor
				if o.Kind == "identity.historical" {
					from = "participant-label/" + o.Attributes["host.label"]
					actors[from] = PFActor{ID: from, Kind: "participant_label", Label: o.Attributes["host.label"]}
				}
				bid := pfID("identity-binding", oid, from, *validator)
				a.Bindings = append(a.Bindings, PFBinding{ID: bid, From: from, To: *validator, Basis: o.Kind, Height: hn, Round: o.Round, SourceRefs: []string{oid}, Reason: o.Attributes["binding.basis"]})
				bindings = append(bindings, bid)
			}
			if validator != nil && o.Kind == "signer.signed" {
				bid := pfID("binding", eid, actor, *validator)
				bindings = append(bindings, bid)
				a.Bindings = append(a.Bindings, PFBinding{ID: bid, From: actor, To: *validator, Basis: derivation, Height: hn, Round: o.Round, SourceRefs: []string{oid}, Reason: o.Attributes["identity.basis"]})
			}
			occurred, ts := "", ""
			if !o.DisplayOnly && !o.Time.IsZero() {
				occurred = iso(o.Time)
				ts = fmt.Sprint(o.Time.Sub(c.Start).Nanoseconds())
			}
			if i, ok := eventIndex[eid]; ok {
				a.Events[i].SourceRefs = append(a.Events[i].SourceRefs, oid)
			} else {
				eventIndex[eid] = len(a.Events)
				a.Events = append(a.Events, PFEvent{ID: eid, Kind: o.Kind, NetworkID: a.Meta.Network, ActorID: actor, ObserverID: o.Observer, ValidatorID: validator, Power: power, Height: hn, Round: o.Round, Phase: o.Phase, Target: o.Target, OccurredAt: occurred, TraceNS: ts, TimeBasis: o.TimeKind, ClockDomain: o.Observer, Derivation: derivation, Temporality: temporality, Verification: "reported", BindingIDs: bindings, SourceRefs: []string{oid}})
			}
			excerpt := o.Message
			if len(excerpt) > 4096 {
				excerpt = excerpt[:4096] + " [excerpt truncated]"
			}
			a.Observations = append(a.Observations, PFObservation{ID: oid, EventID: eid, ObserverID: o.Observer, Kind: o.Kind, ObservedAt: iso(o.Time), CollectedAt: iso(o.CollectedAt), SourceRef: o.Source, Excerpt: redact(excerpt), OriginalAvailable: inputKind == "sample", Attributes: o.Attributes})
			if o.Kind == "commit.certificate" {
				t := c.tally(hn, o.Round, "PRECOMMIT", o.Target, "certificate", o.Observer, o.Source+"/signatures")
				ids := []string{}
				for _, v := range t.Signers {
					ids = append(ids, v.Address)
				}
				ids = unique(ids)
				variant, basis := strings.Join(ids, ","), "signer_set"
				if content := o.Attributes["signature_content"]; content != "" {
					variant, basis = content, "signature_content"
				}
				key := pfID("certificate", fmt.Sprint(hn, o.Round), o.Target, variant)
				v := certs[key]
				if v == nil {
					v = &PFCertificate{ID: key, Height: hn, Round: o.Round, BlockID: o.Target, Signers: ids, VariantBasis: basis, Verification: "reported"}
					if t.Complete {
						v.Power = intp(t.Power)
						v.Quorum = intp(t.Quorum)
					}
					certs[key] = v
				}
				v.Observers = append(v.Observers, o.Observer)
				v.SourceRefs = append(v.SourceRefs, oid)
			}
		}
	}
	knownChanges := map[string]bool{}
	for _, change := range a.Changes {
		knownChanges[change.ID] = true
	}
	for _, change := range c.ImportedChanges {
		if !knownChanges[change.ID] {
			a.Changes = append(a.Changes, change)
			knownChanges[change.ID] = true
		}
	}
	sort.SliceStable(a.Changes, func(i, j int) bool { return a.Changes[i].Height < a.Changes[j].Height })
	// A current host label is useful navigation, not a historical ownership proof.
	addInventoryLabels(&a, actors, c.IdentityLabels)
	for _, e := range a.Events {
		if e.Kind == "current.identity" && e.ValidatorID != nil {
			if actor, ok := actors[*e.ValidatorID]; ok {
				actor.Label += " / current RPC " + e.ObserverID + " (label only)"
				actors[actor.ID] = actor
			}
		}
	}
	normalizeParticipantLabels(actors, &a, c.IdentityLabels)
	for _, k := range sortedKeys(actors) {
		a.Actors = append(a.Actors, actors[k])
	}
	for _, k := range sortedKeys(certs) {
		v := certs[k]
		v.Observers = unique(v.Observers)
		v.SourceRefs = unique(v.SourceRefs)
		a.Certificates = append(a.Certificates, *v)
	}
	a.Meta.FocusHeight = c.To
	for _, h := range c.orderedHeights() {
		if h >= c.From && h <= c.To+1 && len(c.height(h).Observations) > 0 {
			a.Meta.FocusHeight = h
		}
	}
	a.buildRounds(c)
	a.buildSeries(c)
	a.buildIntervalsAndMetrics(c)
	a.buildMembershipSeries(c)
	votes := map[string]*PFVote{}
	for i := range a.Events {
		e := &a.Events[i]
		if (e.Phase != "PREVOTE" && e.Phase != "PRECOMMIT") || (!strings.HasPrefix(e.Kind, "vote.") && e.Kind != "signer.signed") {
			continue
		}
		identity := e.ID
		if e.ValidatorID != nil {
			identity = *e.ValidatorID
		}
		id := pfID(a.Meta.Network, fmt.Sprint(e.Height), fmt.Sprint(e.Round), e.Phase, identity, e.Target)
		if e.Target == "" || strings.HasPrefix(e.Target, "unknown") {
			id = pfID(id, e.ID)
		}
		e.VoteID = id
		v := votes[id]
		if v == nil {
			v = &PFVote{ID: id, Height: e.Height, Round: e.Round, Type: e.Phase, ValidatorID: e.ValidatorID, Target: e.Target}
			votes[id] = v
		}
		v.EventIDs = append(v.EventIDs, e.ID)
		v.SourceRefs = append(v.SourceRefs, e.SourceRefs...)
	}
	for _, id := range sortedKeys(votes) {
		v := votes[id]
		v.EventIDs = unique(v.EventIDs)
		v.SourceRefs = unique(v.SourceRefs)
		a.Votes = append(a.Votes, *v)
	}
	a.Findings = append(a.Findings, "Evidence is scoped to retained sources, not live network health", "Missing votes do not prove a host is offline or its private key is lost", "Generation and clock synchronization may be unknown; signature verification is reported, not cryptographically verified")
	if inputKind == "otlp" {
		a.Coverage = append(a.Coverage, "OTLP-only adapter: raw originals unavailable; display-only anchors are not historical events; certificate grouping uses signer sets")
	}
	return a
}
func sortedKeys[V any](m map[string]V) []string {
	keys := []string{}
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func (a *PFAnalysis) buildRounds(c ConsensusTimeline) {
	eventsByRound := map[[2]int64][]PFEvent{}
	for _, e := range a.Events {
		key := [2]int64{e.Height, e.Round}
		eventsByRound[key] = append(eventsByRound[key], e)
	}
	for _, hn := range c.orderedHeights() {
		if hn < c.From || hn > c.To+1 {
			continue
		}
		h := c.height(hn)
		rounds := []int64{}
		for r := range h.Rounds {
			rounds = append(rounds, r)
		}
		sort.Slice(rounds, func(i, j int) bool { return rounds[i] < rounds[j] })
		for _, r := range rounds {
			modes := []PFRound{{Height: hn, Round: r, Basis: "signing", Temporality: "historical", Observer: "union of signing evidence"}}
			receivers := map[string]bool{}
			for _, o := range h.Observations {
				if o.Round == r && o.Kind == "vote.received" {
					receivers[o.Observer] = true
				}
			}
			for _, observer := range sortedKeys(receivers) {
				modes = append(modes, PFRound{Height: hn, Round: r, Basis: "receipt_log", Temporality: "historical", Observer: observer})
			}
			snapshots := map[string]ConsensusObservation{}
			for _, o := range h.Observations {
				if o.Round == r && o.Kind == "state.snapshot" {
					old, ok := snapshots[o.Observer]
					if !ok || o.CollectedAt.After(old.CollectedAt) {
						snapshots[o.Observer] = o
					}
				}
			}
			for _, n := range sortedKeys(snapshots) {
				o := snapshots[n]
				modes = append(modes, PFRound{Height: hn, Round: r, Basis: "observer_vote_set", Temporality: "snapshot", Observer: n, Source: o.Source, CollectedAt: iso(o.CollectedAt), State: o.Attributes["round_step"]})
			}
			for _, cert := range a.Certificates {
				if cert.Height == hn && cert.Round == r {
					modes = append(modes, PFRound{Height: hn, Round: r, Basis: "commit_certificate", Temporality: "historical", Observer: strings.Join(cert.Observers, ","), Source: cert.ID})
				}
			}
			for _, mode := range modes {
				mode.ID = pfID("round", fmt.Sprint(hn, r), mode.Basis, mode.Observer, mode.Source)
				selected := []PFEvent{}
				for _, e := range eventsByRound[[2]int64{hn, r}] {
					if e.Height != hn || e.Round != r {
						continue
					}
					match := mode.Basis == "signing" && e.Kind == "signer.signed" || mode.Basis == "receipt_log" && e.Kind == "vote.received" && e.ObserverID == mode.Observer
					if mode.Basis == "observer_vote_set" && e.Kind == "vote.snapshot" {
						for _, o := range a.Observations {
							if o.EventID == e.ID && strings.HasPrefix(o.SourceRef, mode.Source+"#bucket/") {
								match = true
							}
						}
					}
					if mode.Basis == "commit_certificate" && e.Kind == "vote.certificate" {
						for _, cert := range a.Certificates {
							if cert.ID == mode.Source && cert.BlockID == e.Target {
								for _, sid := range cert.Signers {
									if e.ValidatorID != nil && *e.ValidatorID == sid {
										match = true
									}
								}
							}
						}
					}
					if match {
						selected = append(selected, e)
					}
				}
				s, ok := h.set("")
				for _, v := range s.Validators {
					row := PFCell{ValidatorID: strp(v.Address), Power: intp(v.Power), IdentityBasis: "observed", Proposal: []string{}, Prevote: []string{}, Precommit: []string{}, EventIDs: []string{}}
					if !ok {
						row.Power = nil
					}
					for _, e := range selected {
						if e.ValidatorID != nil && *e.ValidatorID == v.Address {
							row.EventIDs = append(row.EventIDs, e.ID)
							if e.Derivation == "inferred" {
								row.IdentityBasis = "inferred"
							}
							switch e.Phase {
							case "PROPOSE":
								row.Proposal = append(row.Proposal, e.Target)
							case "PREVOTE":
								row.Prevote = append(row.Prevote, e.Target)
							case "PRECOMMIT":
								row.Precommit = append(row.Precommit, e.Target)
							}
						}
					}
					row.Proposal = unique(row.Proposal)
					row.Prevote = unique(row.Prevote)
					row.Precommit = unique(row.Precommit)
					mode.Rows = append(mode.Rows, row)
				}
				for _, e := range selected {
					if e.ValidatorID == nil {
						mode.Rows = append(mode.Rows, PFCell{ActorID: e.ActorID, IdentityBasis: "unresolved", EventIDs: []string{e.ID}})
					}
				}
				for _, phase := range []string{"PREVOTE", "PRECOMMIT"} {
					targets := map[string]bool{"any": true}
					for _, e := range selected {
						if e.Phase == phase {
							targets[e.Target] = true
						}
					}
					for _, target := range sortedKeys(targets) {
						t := pfTally(s, ok, selected, phase, target)
						mode.Tallies = append(mode.Tallies, t)
					}
				}
				if len(selected) > 0 || mode.Temporality == "snapshot" {
					a.Rounds = append(a.Rounds, mode)
				}
			}
		}
	}
}
func pfTally(s ConsensusSet, complete bool, events []PFEvent, phase, target string) PFTally {
	t := PFTally{Type: phase, Target: target, Condition: "More than 2/3 for this BlockID required", Assessment: "unknown"}
	if target == "any" {
		t.Condition = "More than 2/3 any targets permits wait, not same-block commit"
	}
	if target == "nil" {
		t.Condition = "Nil quorum cannot commit a block"
	}
	if phase == "PREVOTE" && target != "any" && target != "nil" {
		t.Condition = "Prevote quorum permits precommit; it is not a commit certificate"
	}
	if strings.HasPrefix(target, "unknown") {
		t.Condition = "Target unresolved; same-block quorum unknown"
	}
	p, observed := int64(0), int64(0)
	ids, obs := map[string]bool{}, map[string]bool{}
	for _, e := range events {
		if e.Phase != phase || (target != "any" && e.Target != target) {
			continue
		}
		if e.ValidatorID == nil || e.Power == nil {
			t.Unresolved++
			continue
		}
		ids[*e.ValidatorID] = true
		if e.Derivation == "observed" {
			obs[*e.ValidatorID] = true
		}
	}
	if complete {
		for _, v := range s.Validators {
			if ids[v.Address] {
				p += v.Power
			}
			if obs[v.Address] {
				observed += v.Power
			}
		}
		q := quorum(s.Total)
		d := q - p
		if d < 0 {
			d = 0
		}
		t.Power = intp(p)
		t.ObservedOnlyPower = intp(observed)
		t.Total = intp(s.Total)
		t.Quorum = intp(q)
		t.Deficit = intp(d)
		t.Unrepresented = intp(s.Total - p)
		t.Assessment = "not met in selected evidence"
		if d == 0 {
			t.Assessment = "threshold observed, not proof of application commit"
		}
		if strings.HasPrefix(target, "unknown") {
			t.Assessment = "unknown target"
		}
	}
	return t
}
func (a *PFAnalysis) buildSeries(c ConsensusTimeline) {
	events := append([]PFEvent(nil), a.Events...)
	sort.SliceStable(events, func(i, j int) bool {
		if events[i].OccurredAt == events[j].OccurredAt {
			return events[i].ID < events[j].ID
		}
		return timestamp(events[i].OccurredAt).Before(timestamp(events[j].OccurredAt))
	})
	groups := map[string][]PFEvent{}
	for _, e := range events {
		if e.Temporality != "historical" || e.OccurredAt == "" || e.Kind != "signer.signed" || (e.Phase != "PREVOTE" && e.Phase != "PRECOMMIT") {
			continue
		}
		key := fmt.Sprint(e.Height, "/", e.Round, "/", e.Phase, "/", e.Target)
		groups[key] = append(groups[key], e)
		s, ok := c.height(e.Height).set("")
		t := pfTally(s, ok, groups[key], e.Phase, e.Target)
		a.Measurements = append(a.Measurements, PFMeasurement{ID: pfID("signed", key, e.ID), Metric: "consensus.signed_power", Value: t.Power, Unit: "power", Height: e.Height, Round: e.Round, Type: e.Phase, Target: e.Target, Observer: "union of signing evidence", Basis: "signing", Temporality: "historical", IdentityBasis: "mixed", MembershipComplete: ok, Unresolved: t.Unresolved, AsOf: e.OccurredAt, TraceNS: e.TraceNS, SourceRefs: e.SourceRefs, Coverage: "discrete evidence points; no continuous reception coverage"})
	}
	for _, r := range a.Rounds {
		for _, t := range r.Tallies {
			values := map[string]*int64{"consensus.total_power": t.Total, "consensus.quorum_required": t.Quorum, "consensus.quorum_deficit": t.Deficit, "consensus.unrepresented_power": t.Unrepresented, "consensus.unresolved_signatures": intp(int64(t.Unresolved))}
			metric := "consensus.signed_power"
			if r.Basis == "observer_vote_set" {
				metric = "consensus.received_power"
			}
			if r.Basis == "commit_certificate" {
				metric = "consensus.certificate_power"
			}
			if r.Basis == "receipt_log" {
				metric = "consensus.receipt_log_power"
			}
			if t.Target == "any" {
				metric = "consensus.any_target_power"
			}
			values[metric] = t.Power
			for _, k := range sortedKeys(values) {
				unit := "power"
				if k == "consensus.unresolved_signatures" {
					unit = "count"
				}
				a.Measurements = append(a.Measurements, PFMeasurement{ID: pfID(r.ID, t.Type, t.Target, k), Metric: k, Value: values[k], Unit: unit, Height: r.Height, Round: r.Round, Type: t.Type, Target: t.Target, Observer: r.Observer, Basis: r.Basis, Temporality: r.Temporality, IdentityBasis: "mixed", MembershipComplete: t.Total != nil, Unresolved: t.Unresolved, AsOf: r.CollectedAt, SourceRefs: []string{r.Source}, Coverage: "selected sources only; absent does not mean offline"})
			}
		}
	}
}
func analysisRecords(a PFAnalysis) ([]byte, error) {
	var out []byte
	groups := map[string]any{"meta": []PFMeta{a.Meta}, "actor": a.Actors, "binding": a.Bindings, "event": a.Events, "observation": a.Observations, "validator_set": a.Sets, "membership_change": a.Changes, "certificate": a.Certificates, "round_summary": a.Rounds, "measurement": a.Measurements, "interval": a.Intervals, "vote": a.Votes}
	for _, kind := range sortedKeys(groups) {
		b, e := json.Marshal(groups[kind])
		if e != nil {
			return nil, e
		}
		var rows []map[string]any
		if e = json.Unmarshal(b, &rows); e != nil {
			return nil, e
		}
		for _, row := range rows {
			row["record_type"] = kind
			row["schema_version"] = analysisVersion
			b, e = json.Marshal(row)
			if e != nil {
				return nil, e
			}
			out = append(out, b...)
			out = append(out, '\n')
		}
	}
	return out, nil
}
