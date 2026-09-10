package report

import "testing"

func TestNormalizeLegacyPreservesEvidenceLosses(t *testing.T) {
	record, err := NormalizeLegacy(LegacyRecord{SourceRunID: "v2-run-1", CaseID: "case-1", Started: true, Terminal: "failed", RawLogRef: "immutable/log.jsonl"})
	if err != nil {
		t.Fatal(err)
	}
	if record.StepEvidence != "unavailable" || record.DurationEvidence != "unavailable" {
		t.Fatalf("legacy result inferred execution details: %+v", record)
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
