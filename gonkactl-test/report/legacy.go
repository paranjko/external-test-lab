package report

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// LegacyRecord is intentionally narrower than an Allure 2 result. A legacy
// renderer's inferred step statuses and render-time durations are never input
// to the new execution evidence lineage.
type LegacyRecord struct {
	SourceRunID   string
	CaseID        string
	Started       bool
	Terminal      string
	RawLogRef     string
	StartedAt     string
	FinishedAt    string
	ArchiveSHA256 string
}

type NormalizedLegacyRecord struct {
	SourceRunID           string `json:"source_run_id"`
	CaseID                string `json:"case_id"`
	Outcome               string `json:"outcome"`
	RawLogRef             string `json:"raw_log_ref"`
	NormalizationRevision string `json:"normalization_revision"`
	StepEvidence          string `json:"step_evidence"`
	DurationEvidence      string `json:"duration_evidence"`
	StartedAt             string `json:"started_at"`
	FinishedAt            string `json:"finished_at"`
	ArchiveSHA256         string `json:"archive_sha256"`
	IdentityMapping       string `json:"identity_mapping"`
}

// NormalizeLegacy accepts only independently evidenced start and terminal
// events. It preserves provenance and explicitly records the evidence losses.
func NormalizeLegacy(record LegacyRecord) (NormalizedLegacyRecord, error) {
	if record.SourceRunID == "" || record.CaseID == "" || record.RawLogRef == "" {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy provenance is incomplete")
	}
	if record.ArchiveSHA256 == "" {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy archive hash is missing")
	}
	if len(record.ArchiveSHA256) != sha256.Size*2 {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy archive hash is invalid")
	}
	if _, err := hex.DecodeString(record.ArchiveSHA256); err != nil {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy archive hash is invalid: %w", err)
	}
	if !record.Started {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy case %q has no start event", record.CaseID)
	}
	switch record.Terminal {
	case "passed", "failed", "broken", "skipped":
	default:
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy case %q has no supported terminal outcome", record.CaseID)
	}
	if record.StartedAt == "" {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy case %q has no start timestamp", record.CaseID)
	}
	if _, err := time.Parse(time.RFC3339Nano, record.StartedAt); err != nil {
		return NormalizedLegacyRecord{}, fmt.Errorf("invalid legacy start timestamp: %w", err)
	}
	if record.FinishedAt == "" {
		return NormalizedLegacyRecord{}, fmt.Errorf("legacy case %q has no terminal timestamp", record.CaseID)
	}
	if _, err := time.Parse(time.RFC3339Nano, record.FinishedAt); err != nil {
		return NormalizedLegacyRecord{}, fmt.Errorf("invalid legacy terminal timestamp: %w", err)
	}
	return NormalizedLegacyRecord{SourceRunID: record.SourceRunID, CaseID: record.CaseID, Outcome: record.Terminal, RawLogRef: record.RawLogRef, NormalizationRevision: "legacy-v2-to-v3-v1", StepEvidence: "unavailable", DurationEvidence: "unavailable", StartedAt: record.StartedAt, FinishedAt: record.FinishedAt, ArchiveSHA256: record.ArchiveSHA256, IdentityMapping: "legacy-case:" + record.CaseID}, nil
}

// ImportLegacyArchive validates an immutable raw JSONL archive. Rendered HTML,
// malformed records and cases without both start and terminal evidence fail closed.
func ImportLegacyArchive(path string) ([]NormalizedLegacyRecord, error) {
	if strings.EqualFold(filepath.Ext(path), ".html") {
		return nil, fmt.Errorf("HTML-only legacy import is not evidence")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(b)
	type event struct {
		SourceRunID string `json:"source_run_id"`
		CaseID      string `json:"case_id"`
		Kind        string `json:"kind"`
		Outcome     string `json:"outcome"`
		Timestamp   string `json:"timestamp"`
	}
	states := map[string]*LegacyRecord{}
	s := bufio.NewScanner(strings.NewReader(string(b)))
	for s.Scan() {
		var e event
		if err := json.Unmarshal(s.Bytes(), &e); err != nil {
			return nil, fmt.Errorf("malformed legacy archive: %w", err)
		}
		if e.SourceRunID == "" || e.CaseID == "" {
			return nil, fmt.Errorf("legacy event provenance is incomplete")
		}
		k := e.SourceRunID + "\x00" + e.CaseID
		r := states[k]
		if r == nil {
			r = &LegacyRecord{SourceRunID: e.SourceRunID, CaseID: e.CaseID, RawLogRef: path, ArchiveSHA256: hex.EncodeToString(sum[:])}
			states[k] = r
		}
		switch e.Kind {
		case "case_started":
			r.Started = true
			r.StartedAt = e.Timestamp
		case "case_finished":
			r.Terminal = e.Outcome
			r.FinishedAt = e.Timestamp
		}
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	var out []NormalizedLegacyRecord
	for _, r := range states {
		n, err := NormalizeLegacy(*r)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("legacy archive contains no cases")
	}
	return out, nil
}
