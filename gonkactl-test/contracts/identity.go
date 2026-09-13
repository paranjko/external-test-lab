package contracts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

const SchemaVersion = "1.0.0"

// SemanticIdentityV1 contains exactly the stable inputs specified by FR-009.
// Execution IDs, timestamps, and artifact digests must remain metadata.
type SemanticIdentityV1 struct {
	ScenarioID            string
	ContractRevision      string
	VariantID             string
	EnvironmentClass      string
	ComputeMode           string
	ComparisonSlot        string
	HistoryPolicyRevision string
}

func (i SemanticIdentityV1) HistoryID() (string, error) {
	fields := map[string]string{
		"comparison_slot":         i.ComparisonSlot,
		"compute_mode":            i.ComputeMode,
		"contract_revision":       i.ContractRevision,
		"environment_class":       i.EnvironmentClass,
		"history_policy_revision": i.HistoryPolicyRevision,
		"scenario_id":             i.ScenarioID,
		"variant_id":              i.VariantID,
	}
	for name, value := range fields {
		if value == "" {
			return "", fmt.Errorf("semantic identity field %s is empty", name)
		}
	}
	canonical, err := json.Marshal(fields) // encoding/json sorts map keys.
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}
