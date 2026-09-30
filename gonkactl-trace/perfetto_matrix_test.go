package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestPerfettoMatrixSubset(t *testing.T) {
	a := PFAnalysis{Events: []PFEvent{{ID: "before", Height: 306549}, {ID: "inside", Height: 306550, BindingIDs: []string{"binding"}}, {ID: "snapshot", Height: 306553, Temporality: "snapshot"}, {ID: "jail", Height: 306511, Kind: "validator.jailed.liveness"}, {ID: "future", Height: 306554, Kind: "validator.jailed.liveness"}}, Observations: []PFObservation{{ID: "o", EventID: "inside", Excerpt: "retained"}, {ID: "old", EventID: "before"}}, Sets: []PFSet{{Height: 306549}, {Height: 306550}}, Bindings: []PFBinding{{ID: "binding"}, {ID: "unrelated"}}}
	m := matrixSubset(a)
	if len(m.Events) != 3 || len(m.Observations) != 1 || len(m.Sets) != 1 || len(m.Bindings) != 1 {
		t.Fatalf("bad subset: %+v", m)
	}
	if m.Observations[0].Excerpt != "retained" || m.Events[1].Temporality != "snapshot" {
		t.Fatal("evidence transformed")
	}
	if len(a.Events) != 5 {
		t.Fatal("source changed")
	}
	h := perfettoHandler("http://localhost", "sample", t.TempDir(), a, fstest.MapFS{})
	for _, tc := range []struct{ path, contains string }{{"/gonka/", "state matrix prototype"}, {"/gonka/?view=timeline", "Loading offline Perfetto"}, {"/gonka/matrix.mjs", "buildMatrix"}, {"/api/session/sample/matrix", "validator_sets"}} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", "http://localhost"+tc.path, nil))
		if w.Code != 200 || !strings.Contains(w.Body.String(), tc.contains) {
			t.Fatalf("%s: %d %s", tc.path, w.Code, w.Body.String())
		}
		if strings.HasSuffix(tc.path, "/matrix") {
			var decoded PFMatrix
			if err := json.Unmarshal(w.Body.Bytes(), &decoded); err != nil || len(decoded.Events) != 3 {
				t.Fatal("bad matrix response")
			}
		}
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "http://evil/gonka/matrix.mjs", nil))
	if w.Code != 403 {
		t.Fatal("host guard bypass")
	}
}

func TestPerfettoMatrixAdmissionProvenance(t *testing.T) {
	a := PFAnalysis{Actors: []PFActor{{ID: "key", Kind: "consensus_identity", Participant: "node5-2"}}, Sets: []PFSet{
		{Height: 306273, Validators: []ConsensusValidator{{Address: "key", Power: 57}}},
		{Height: 306133, Validators: []ConsensusValidator{{Address: "key", Power: 70}}},
	}, Changes: []PFChange{{Height: 306553}, {Height: 306133}}, Certificates: []PFCertificate{{Height: 306551, SourceRefs: []string{"ref"}}, {Height: 306133}}, Observations: []PFObservation{{ID: "ref", EventID: "unlisted", Excerpt: "certificate evidence"}}}
	m := matrixSubset(a)
	if len(m.PriorSets) != 1 || m.PriorSets[0].Height != 306133 {
		t.Fatal("first retained positive set not preserved")
	}
	if len(m.Changes) != 1 || len(m.Certificates) != 1 || len(m.Observations) != 1 {
		t.Fatal("admission provenance closure lost")
	}
	if m.Observations[0].Excerpt != "certificate evidence" {
		t.Fatal("certificate source altered")
	}
}
