package coregate

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestParseBarrierMarkerMatchesActualProducerFormat(t *testing.T) {
	for _, stage := range []BarrierStage{HandshakeReplay, HandshakeAlreadySynced, ConsensusFinalize} {
		want, marker := markerFixture(stage)
		raw, err := json.Marshal(marker)
		if err != nil {
			t.Fatal(err)
		}
		got, err := ParseBarrierMarker(append(raw, '\n'), want)
		if err != nil || got != marker {
			t.Fatalf("marker=%+v err=%v", got, err)
		}
	}
}

func TestParseBarrierMarkerRejectsSubstitutionAndPartialIdentity(t *testing.T) {
	want, original := markerFixture(HandshakeReplay)
	for name, change := range map[string]func(*BarrierMarker){
		"chain":      func(m *BarrierMarker) { m.ChainID = "other" },
		"height":     func(m *BarrierMarker) { m.Height++ },
		"stage":      func(m *BarrierMarker) { m.Stage = HandshakeAlreadySynced },
		"app hash":   func(m *BarrierMarker) { m.AppHash = strings.Repeat("f", 64) },
		"hash only":  func(m *BarrierMarker) { m.BlockID = strings.ToUpper(want.BlockHash) },
		"part total": func(m *BarrierMarker) { m.BlockID = strings.Replace(m.BlockID, "/1:", "/2:", 1) },
		"part hash":  func(m *BarrierMarker) { m.BlockID = strings.ToUpper(want.BlockHash) + "/1:" + strings.Repeat("F", 64) },
		"hostname":   func(m *BarrierMarker) { m.Hostname = "foreign-container" },
		"pid":        func(m *BarrierMarker) { m.PID++ },
	} {
		t.Run(name, func(t *testing.T) {
			m := original
			change(&m)
			raw, err := json.Marshal(m)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := ParseBarrierMarker(raw, want); !errors.Is(err, ErrBarrierMarker) {
				t.Fatalf("accepted substitution: %v", err)
			}
		})
	}
	raw, _ := json.Marshal(original)
	for name, data := range map[string][]byte{
		"duplicate": append([]byte(`{"height":370,`), raw[1:]...),
		"unknown":   append([]byte(`{"run_id":"fake",`), raw[1:]...),
		"truncated": raw[:len(raw)-1],
		"oversized": []byte(strings.Repeat(" ", 16<<10+1)),
		"null":      []byte("null"),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseBarrierMarker(data, want); !errors.Is(err, ErrBarrierMarker) {
				t.Fatalf("accepted malformed record: %v", err)
			}
		})
	}
}

func TestParseBarrierMarkerRequiresIndependentCompleteExpectation(t *testing.T) {
	want, marker := markerFixture(HandshakeReplay)
	raw, _ := json.Marshal(marker)
	want.Hostname = ""
	if _, err := ParseBarrierMarker(raw, want); !errors.Is(err, ErrBarrierMarker) {
		t.Fatal("accepted absent inspected identity")
	}
	want, _ = markerFixture(HandshakeReplay)
	want.Stage = "unknown"
	if _, err := ParseBarrierMarker(raw, want); !errors.Is(err, ErrBarrierMarker) {
		t.Fatal("accepted unsupported stage")
	}
}

func markerFixture(stage BarrierStage) (BarrierMarkerExpectation, BarrierMarker) {
	w := BarrierMarkerExpectation{ChainID: "gnk2-261019-1550-double", Height: 370, Stage: stage, AppHash: strings.Repeat("a", 64), BlockHash: strings.Repeat("b", 64), PartSetTotal: 1, PartSetHash: strings.Repeat("c", 64), Hostname: "owned-container-id", PID: 1}
	return w, BarrierMarker{ChainID: w.ChainID, Height: w.Height, Stage: w.Stage, AppHash: w.AppHash, BlockID: strings.Repeat("B", 64) + "/1:" + strings.Repeat("C", 64), Hostname: w.Hostname, PID: w.PID}
}
