package harness

import (
	"bytes"
	"strings"
	"testing"
)

func TestTraceJSONRoundTripAndAcceptanceReplay(t *testing.T) {
	trace := testTrace(Lifecycle, "synthetic-lifecycle-run")
	var encoded bytes.Buffer
	if err := EncodeTrace(&encoded, trace); err != nil {
		t.Fatal(err)
	}
	result, err := DecodeAndValidateTrace(&encoded, requirements(Lifecycle))
	if err != nil {
		t.Fatal(err)
	}
	if !result.ConsistencyChecked || result.RunID != "synthetic-lifecycle-run" {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestTraceJSONRejectsUnknownDuplicateAndTrailingFields(t *testing.T) {
	trace := testTrace(OneUpdate, "strict-decoder-run")
	var encoded bytes.Buffer
	if err := EncodeTrace(&encoded, trace); err != nil {
		t.Fatal(err)
	}
	valid := encoded.String()
	cases := map[string]string{
		"unknown field":    strings.Replace(valid, `"run_id": "strict-decoder-run"`, `"run_id": "strict-decoder-run", "runtime_qualified": true`, 1),
		"duplicate field":  strings.Replace(valid, `"run_id": "strict-decoder-run"`, `"run_id": "strict-decoder-run", "run_id": "other"`, 1),
		"trailing object":  valid + `{}`,
		"trailing garbage": valid + `garbage`,
	}
	for name, document := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeTrace(strings.NewReader(document)); err == nil {
				t.Fatal("invalid document accepted")
			}
		})
	}
}

func TestTraceJSONRequiresRunBindingAndObservations(t *testing.T) {
	if _, err := DecodeTrace(strings.NewReader(`{"binding":{},"observations":[]}`)); err == nil {
		t.Fatal("empty/unbound document accepted")
	}
	trace := testTrace(OneUpdate, "empty-observation-run")
	trace.Observations = nil
	var encoded bytes.Buffer
	if err := EncodeTrace(&encoded, trace); err == nil {
		t.Fatal("producer encoded empty observation stream")
	}
}

func TestTraceJSONPreservesRunArtifactAndEventOrderingChecks(t *testing.T) {
	trace := testTrace(Lifecycle, "replayable-run")
	var encoded bytes.Buffer
	if err := EncodeTrace(&encoded, trace); err != nil {
		t.Fatal(err)
	}
	doc := encoded.String()
	// A changed run/artifact/event is accepted as syntax but rejected by the
	// requirement validator; decoding cannot turn a claim into proof.
	mutations := map[string]string{
		"mixed run":        strings.Replace(doc, `"run_id": "replayable-run"`, `"run_id": "foreign-run"`, 1),
		"wrong artifact":   strings.Replace(doc, strings.Repeat("e", 64), strings.Repeat("8", 64), 1),
		"out of order":     strings.Replace(doc, `"sequence": 2`, `"sequence": 1`, 1),
		"missing evidence": strings.ReplaceAll(doc, strings.Repeat("f", 64), ""),
	}
	for name, document := range mutations {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeAndValidateTrace(strings.NewReader(document), requirements(Lifecycle)); err == nil {
				t.Fatal("invalid trace accepted")
			}
		})
	}
}
