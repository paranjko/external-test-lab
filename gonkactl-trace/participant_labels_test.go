package main

import (
	"strings"
	"testing"
)

func TestParticipantLabelsPreserveEvidenceBoundaries(t *testing.T) {
	id := strings.Repeat("A", 40)
	actors := map[string]PFActor{
		id:                           {ID: id, Kind: "consensus_identity"},
		"core@node1/source-abc":      {ID: "core@node1/source-abc", Kind: "core"},
		"signer@node1/container-def": {ID: "signer@node1/container-def", Kind: "signer"},
	}
	a := PFAnalysis{Events: []PFEvent{{Kind: "current.identity", ObserverID: "node1", ValidatorID: &id}}}
	normalizeParticipantLabels(actors, &a, nil)
	for key, actor := range actors {
		if actor.ID != key || actor.Participant != "node1" || !strings.HasPrefix(actor.Label, "node1 · ") || actor.LabelBasis == "" {
			t.Fatalf("invalid presentation: %+v", actor)
		}
	}
	if !strings.Contains(actors[id].LabelBasis, "historical host ownership not established") {
		t.Fatal("current identity promoted to historical binding")
	}
	normalizeParticipantLabels(actors, &a, []InventoryLabel{{Node: "node5-1", Validator: id, Source: "operator inventory"}})
	if actors[id].Participant != "node5-1" {
		t.Fatal("explicit inventory label overridden by current RPC")
	}
}

func TestParticipantLabelConflict(t *testing.T) {
	id := strings.Repeat("B", 40)
	actors := map[string]PFActor{id: {ID: id, Kind: "consensus_identity"}}
	a := PFAnalysis{}
	normalizeParticipantLabels(actors, &a, []InventoryLabel{{Node: "node5-1", Validator: id, Source: "one"}, {Node: "node5-2", Validator: id, Source: "two"}})
	if actors[id].Participant != "" || len(a.Coverage) != 1 {
		t.Fatal("conflicting aliases silently accepted")
	}
}
