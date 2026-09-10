package report

import "fmt"

// LegacyRecord is intentionally narrower than an Allure 2 result. A legacy
// renderer's inferred step statuses and render-time durations are never input
// to the new execution evidence lineage.
type LegacyRecord struct {
	SourceRunID string
	CaseID      string
	Started     bool
	Terminal    string
	RawLogRef   string
}

type NormalizedLegacyRecord struct {
	SourceRunID           string `json:"source_run_id"`
	CaseID                string `json:"case_id"`
	Outcome               string `json:"outcome"`
	RawLogRef             string `json:"raw_log_ref"`
	NormalizationRevision string `json:"normalization_revision"`
	StepEvidence          string `json:"step_evidence"`
	DurationEvidence      string `json:"duration_evidence"`
}

// NormalizeLegacy accepts only independently evidenced start and terminal
// events. It preserves provenance and explicitly records the evidence losses.
func NormalizeLegacy(record LegacyRecord) (NormalizedLegacyRecord, error) {
	if record.SourceRunID == "" || record.CaseID == "" || record.RawLogRef == "" {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy provenance is incomplete")
	}
	if !record.Started {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy case %q has no start event", record.CaseID)
	}
	switch record.Terminal {
	case "passed", "failed", "broken", "skipped":
	default:
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy case %q has no supported terminal outcome", record.CaseID)
	}
	return NormalizedLegacyRecord{SourceRunID: record.SourceRunID, CaseID: record.CaseID, Outcome: record.Terminal, RawLogRef: record.RawLogRef, NormalizationRevision: "legacy-v2-to-v3-v1", StepEvidence: "unavailable", DurationEvidence: "unavailable"}, nil
}
