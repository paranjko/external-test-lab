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

// WriteLegacyLane retains normalized legacy records in a distinct,
// non-authentic lane. It deliberately refuses a history destination: legacy
// evidence may be visible to operators, but it can never become a v3 history
// point or an authentic execution result by this path.
func WriteLegacyLane(archivePath, outputPath string) (string, error) {
	records, err := ImportLegacyArchive(archivePath)
	if err != nil {
		return "", err
	}
	for i := range records {
		// The lane is relocatable; keep the immutable archive filename while the
		// hash remains the stable provenance binding.
		records[i].RawLogRef = filepath.Base(archivePath)
	}
	return writeLegacyLane(filepath.Base(archivePath), records, outputPath)
}

func writeLegacyLane(archive string, records []NormalizedLegacyRecord, outputPath string) (string, error) {
	clean := filepath.Clean(outputPath)
	for _, part := range strings.Split(filepath.ToSlash(clean), "/") {
		if part == "history" {
			return "", fmt.Errorf("legacy lane must not write into authentic history")
		}
	}
	payload := struct {
		Lane    string                   `json:"lane"`
		Archive string                   `json:"archive"`
		Records []NormalizedLegacyRecord `json:"records"`
	}{Lane: "legacy-unqualified", Archive: archive, Records: records}
	b, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return "", err
	}
	if err := atomicWrite(outputPath, append(b, '\n'), 0o644); err != nil {
		return "", err
	}
	return outputPath, nil
}

// ImportLegacyAllure2Directory accepts immutable raw Allure 2 result files
// only as legacy evidence. It requires an executor build name for source-run
// provenance and refuses incomplete result timing or terminal status.
func ImportLegacyAllure2Directory(directory string) ([]NormalizedLegacyRecord, error) {
	executorBytes, err := os.ReadFile(filepath.Join(directory, "executor.json"))
	if err != nil {
		return nil, fmt.Errorf("read Allure 2 executor provenance: %w", err)
	}
	var executor struct {
		BuildName string `json:"buildName"`
	}
	if err := json.Unmarshal(executorBytes, &executor); err != nil || executor.BuildName == "" {
		return nil, fmt.Errorf("Allure 2 executor buildName is required")
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	var records []NormalizedLegacyRecord
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), "-result.json") {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var raw struct {
			UUID   string `json:"uuid"`
			Name   string `json:"name"`
			Status string `json:"status"`
			Start  int64  `json:"start"`
			Stop   int64  `json:"stop"`
		}
		if err := json.Unmarshal(b, &raw); err != nil {
			return nil, fmt.Errorf("decode Allure 2 raw result %s: %w", entry.Name(), err)
		}
		if raw.UUID == "" || raw.Name == "" || raw.Start <= 0 || raw.Stop <= raw.Start {
			return nil, fmt.Errorf("Allure 2 raw result %s lacks identity/timing evidence", entry.Name())
		}
		sum := sha256.Sum256(b)
		started := time.UnixMilli(raw.Start).UTC().Format(time.RFC3339Nano)
		finished := time.UnixMilli(raw.Stop).UTC().Format(time.RFC3339Nano)
		normalized, err := NormalizeLegacy(LegacyRecord{SourceRunID: executor.BuildName, CaseID: raw.UUID, Started: true, Terminal: raw.Status, RawLogRef: entry.Name(), StartedAt: started, FinishedAt: finished, ArchiveSHA256: hex.EncodeToString(sum[:])})
		if err != nil {
			return nil, err
		}
		records = append(records, normalized)
	}
	if len(records) == 0 {
		return nil, fmt.Errorf("Allure 2 raw archive contains no result files")
	}
	return records, nil
}

// WriteLegacyAllure2Lane publishes raw Allure 2 results only through the
// non-authentic legacy lane; it shares the same history exclusion as JSONL.
func WriteLegacyAllure2Lane(directory, outputPath string) (string, error) {
	records, err := ImportLegacyAllure2Directory(directory)
	if err != nil {
		return "", err
	}
	return writeLegacyLane(filepath.Base(filepath.Clean(directory)), records, outputPath)
}
