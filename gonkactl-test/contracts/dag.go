package contracts

import "fmt"

type Prerequisite struct {
	ID        string
	DependsOn []string
}

// ValidateDAG rejects duplicate IDs, unknown dependencies, self-edges, and cycles.
func ValidateDAG(nodes []Prerequisite) error {
	byID := make(map[string]Prerequisite, len(nodes))
	for _, node := range nodes {
		if node.ID == "" {
			return fmt.Errorf("prerequisite ID is empty")
		}
		if _, exists := byID[node.ID]; exists {
			return fmt.Errorf("duplicate prerequisite ID %q", node.ID)
		}
		byID[node.ID] = node
	}
	for _, node := range nodes {
		for _, dependency := range node.DependsOn {
			if dependency == node.ID {
				return fmt.Errorf("prerequisite %q depends on itself", node.ID)
			}
			if _, exists := byID[dependency]; !exists {
				return fmt.Errorf("prerequisite %q has unknown dependency %q", node.ID, dependency)
			}
		}
	}
	state := make(map[string]uint8, len(nodes))
	var visit func(string) error
	visit = func(id string) error {
		if state[id] == 1 {
			return fmt.Errorf("prerequisite cycle includes %q", id)
		}
		if state[id] == 2 {
			return nil
		}
		state[id] = 1
		for _, dependency := range byID[id].DependsOn {
			if err := visit(dependency); err != nil {
				return err
			}
		}
		state[id] = 2
		return nil
	}
	for id := range byID {
		if err := visit(id); err != nil {
			return err
		}
	}
	return nil
}

// BlockedBy returns only direct failed prerequisites. The scheduler propagates
// not-run through the DAG by recording each blocked result before its dependents.
func BlockedBy(node Prerequisite, outcomes map[string]bool) []string {
	var blocked []string
	for _, dependency := range node.DependsOn {
		if passed, known := outcomes[dependency]; !known || !passed {
			blocked = append(blocked, dependency)
		}
	}
	return blocked
}
