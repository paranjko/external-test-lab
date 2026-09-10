package bindings

import "fmt"

// ValidateJournalIntegrity enforces the cross-record identity and terminal
// invariants that JSON Schema cannot express.
func ValidateJournalIntegrity(events []JournalEvent) error {
	eventIDs := map[string]bool{}
	started := map[string]bool{}
	finished := map[string]bool{}
	lastSeq := int64(0)
	lastElapsed := int64(0)
	for _, e := range events {
		if eventIDs[e.EventID] {
			return fmt.Errorf("duplicate event id %q", e.EventID)
		}
		eventIDs[e.EventID] = true
		if e.Sequence != lastSeq+1 {
			return fmt.Errorf("sequence %d follows %d", e.Sequence, lastSeq)
		}
		lastSeq = e.Sequence
		if e.ElapsedMS < lastElapsed {
			return fmt.Errorf("elapsed time regressed at %s", e.EventID)
		}
		lastElapsed = e.ElapsedMS
		if e.CaseID != nil {
			caseID := *e.CaseID
			switch e.Kind {
			case "case_started":
				if started[caseID] {
					return fmt.Errorf("duplicate case id %q", caseID)
				}
				started[caseID] = true
			case "case_finished", "interrupted":
				if !started[caseID] {
					return fmt.Errorf("unknown case id %q", caseID)
				}
				if finished[caseID] {
					return fmt.Errorf("duplicate terminal case id %q", caseID)
				}
				finished[caseID] = true
			default:
				if !started[caseID] {
					return fmt.Errorf("unknown case id %q", caseID)
				}
			}
		}
	}
	for id := range started {
		if !finished[id] {
			return fmt.Errorf("case %q has no terminal event", id)
		}
	}
	return nil
}
