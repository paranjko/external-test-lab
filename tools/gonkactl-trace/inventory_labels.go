package main

import "fmt"

// Operator attribution is presentation metadata, never a signing-key binding.
type InventoryLabel struct {
	Node      string `json:"node"`
	Validator string `json:"validator"`
	Source    string `json:"source"`
}

func addInventoryLabels(a *PFAnalysis, actors map[string]PFActor, labels []InventoryLabel) {
	for i, label := range labels {
		if !safeID.MatchString(label.Node) || !validIdentity(label.Validator) || label.Source == "" {
			a.Coverage = append(a.Coverage, "Invalid inventory annotation ignored")
			continue
		}
		actor, ok := actors[label.Validator]
		if !ok {
			continue
		}
		actor.Label += " / " + label.Node + " (operator attribution)"
		actors[actor.ID] = actor
		oid := pfID("inventory", label.Node, label.Validator, label.Source)
		a.Observations = append(a.Observations, PFObservation{ID: oid, Kind: "inventory.annotation", SourceRef: fmt.Sprintf("input dataset#/config/identity_labels/%d", i), Excerpt: label.Source,
			Attributes: map[string]string{"node": label.Node, "validator": label.Validator, "basis": "operator attribution only; not independent historical host ownership or signer availability"}})
		a.Findings = append(a.Findings, fmt.Sprintf("%s label for %s is operator inventory attribution, not proof of physical signing location", label.Node, label.Validator))
	}
}
