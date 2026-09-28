package main

import "strings"

// Presentation groups are not identity bindings. Actor IDs, generation evidence,
// and historical/current identity boundaries remain unchanged.
func normalizeParticipantLabels(actors map[string]PFActor, a *PFAnalysis, labels []InventoryLabel) {
	names, bases := map[string]string{}, map[string]string{}
	conflicts := map[string]bool{}
	for _, label := range labels {
		if !safeID.MatchString(label.Node) || !validIdentity(label.Validator) || label.Source == "" {
			continue
		}
		if old := names[label.Validator]; old != "" && old != label.Node {
			conflicts[label.Validator] = true
		}
		names[label.Validator], bases[label.Validator] = label.Node, label.Source
	}
	for id := range conflicts {
		delete(names, id)
		a.Coverage = append(a.Coverage, "Conflicting participant labels for "+id+"; participant left unresolved")
	}
	for _, e := range a.Events {
		if e.Kind == "current.identity" && e.ValidatorID != nil && names[*e.ValidatorID] == "" && !conflicts[*e.ValidatorID] {
			names[*e.ValidatorID] = e.ObserverID
			bases[*e.ValidatorID] = "current RPC identity; historical host ownership not established"
		}
	}
	for id, actor := range actors {
		if actor.Kind == "consensus_identity" {
			if name := names[id]; name != "" {
				actor.Participant, actor.LabelBasis = name, bases[id]
				actor.Label = name + " · consensus"
			}
		} else if before, after, ok := strings.Cut(id, "@"); ok {
			node, stream, _ := strings.Cut(after, "/")
			actor.Participant = node
			actor.LabelBasis = "source observer; grouping does not establish signing identity or process generation"
			actor.Label = node + " · " + before
			if strings.HasPrefix(stream, "source-") {
				actor.Label += " · source " + short(strings.TrimPrefix(stream, "source-"))
			} else if strings.HasPrefix(stream, "container-") {
				actor.Label += " · container " + short(strings.TrimPrefix(stream, "container-"))
			}
		}
		actors[id] = actor
	}
}
