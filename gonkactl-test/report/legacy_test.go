package report

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizeLegacyPreservesEvidenceLosses(t *testing.T) {
	record, err := NormalizeLegacy(LegacyRecord{SourceRunID: "v2-run-1", CaseID: "case-1", Started: true, Terminal: "failed", RawLogRef: "immutable/log.jsonl"})
	if err != nil {
		t.Fatal(err)
	}
	if record.StepEvidence != "unavailable" || record.DurationEvidence != "unavailable" {
		t.Fatalf("legacy result inferred execution details: %+v", record)
	}
}

func TestImportLegacyArchiveValidatesImmutableProvenance(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "allure2-events.jsonl")
	data := "{\"source_run_id\":\"old-1\",\"case_id\":\"case-1\",\"kind\":\"case_started\",\"timestamp\":\"2026-01-01T00:00:00Z\"}\n{\"source_run_id\":\"old-1\",\"case_id\":\"case-1\",\"kind\":\"case_finished\",\"outcome\":\"passed\",\"timestamp\":\"2026-01-01T00:00:01Z\"}\n"
	if err := os.WriteFile(p, []byte(data), 0444); err != nil {
		t.Fatal(err)
	}
	got, err := ImportLegacyArchive(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ArchiveSHA256 == "" || got[0].IdentityMapping != "legacy-case:case-1" {
		t.Fatalf("provenance=%+v", got)
	}
	if _, err := ImportLegacyArchive(filepath.Join(d, "index.html")); err == nil {
		t.Fatal("HTML-only import accepted")
	}
}

func TestNormalizeLegacyRejectsHtmlOnlyOrOutcomeLessRecord(t *testing.T) {
	if _, err := NormalizeLegacy(LegacyRecord{SourceRunID: "v2-html", CaseID: "case-1", Started: false, Terminal: "passed", RawLogRef: "legacy/index.html"}); err == nil {
		t.Fatal("HTML-only legacy record accepted")
	}
	if _, err := NormalizeLegacy(LegacyRecord{SourceRunID: "v2-partial", CaseID: "case-2", Started: true, RawLogRef: "immutable/log.jsonl"}); err == nil {
		t.Fatal("outcome-less legacy record accepted")
	}
}
