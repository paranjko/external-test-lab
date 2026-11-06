package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
)

func TestPerfettoTallyBoundaries(t *testing.T) {
	c := fixtureConsensus()
	s, _ := c.height(7).set("")
	a, b := s.Validators[0], s.Validators[2]
	es := []PFEvent{
		{ValidatorID: strp(a.Address), Power: intp(a.Power), Phase: "PREVOTE", Target: "nil", Derivation: "observed"},
		{ValidatorID: strp(a.Address), Power: intp(a.Power), Phase: "PREVOTE", Target: "nil", Derivation: "observed"},
		{ValidatorID: strp(b.Address), Power: intp(b.Power), Phase: "PREVOTE", Target: "nil", Derivation: "inferred"},
		{Phase: "PREVOTE", Target: "unknown:prefix", Derivation: "unresolved"},
	}
	v := pfTally(s, true, es, "PREVOTE", "nil")
	if *v.Power != 81 || *v.ObservedOnlyPower != 54 || *v.Quorum != 91 || *v.Deficit != 10 || *v.Unrepresented != 54 {
		t.Fatal(v)
	}
	if !strings.Contains(v.Condition, "cannot commit") {
		t.Fatal(v.Condition)
	}
	if got := pfTally(s, false, es, "PREVOTE", "any"); got.Power != nil || got.Quorum != nil {
		t.Fatal("incomplete set got numeric quorum", got)
	}
	if got := pfTally(s, true, es, "PREVOTE", "unknown:prefix"); got.Unresolved != 1 || got.Assessment != "unknown target" {
		t.Fatal(got)
	}
	// Conflicting targets remain separate; any-target union counts identity once.
	es = append(es, PFEvent{ValidatorID: strp(a.Address), Power: intp(a.Power), Phase: "PREVOTE", Target: "other", Derivation: "observed"})
	if got := pfTally(s, true, es, "PREVOTE", "any"); *got.Power != 81 {
		t.Fatal(got)
	}
}

func TestPerfettoSnapshotsAreNotHistory(t *testing.T) {
	c := fixtureConsensus()
	c.Start = timestamp("2026-09-09T18:59:33Z")
	c.End = c.Start.Add(time.Second)
	c.add(ConsensusObservation{Height: 7, Round: 0, Observer: "n1", Kind: "vote.snapshot", Phase: "PREVOTE", Validator: strings.Repeat("A", 40), Target: "nil", Time: c.Start, CollectedAt: c.Start.Add(24 * time.Hour), DisplayOnly: true, Source: "snapshot"})
	c.add(ConsensusObservation{Height: 7, Round: 0, Observer: "n1", Kind: "signer.signed", Phase: "PREVOTE", Target: "nil", Time: c.Start.Add(time.Millisecond), Source: "signer"})
	a := makeAnalysis(c, "fixture", "sample")
	for _, e := range a.Events {
		if e.Kind == "vote.snapshot" && (e.TraceNS != "" || e.OccurredAt != "") {
			t.Fatal("snapshot invented time", e)
		}
		if e.Kind == "signer.signed" && (e.ValidatorID != nil || e.Power != nil) {
			t.Fatal("unknown signer erased", e)
		}
	}
	trace := nativePerfetto(a)
	if !bytes.Equal(trace, nativePerfetto(a)) {
		t.Fatal("nondeterministic trace")
	}
	for len(trace) > 0 {
		n, typ, used := protowire.ConsumeTag(trace)
		if n != 1 || typ != protowire.BytesType || used < 0 {
			t.Fatal("not native Trace packet")
		}
		_, size := protowire.ConsumeBytes(trace[used:])
		if size < 0 {
			t.Fatal("truncated packet")
		}
		trace = trace[used+size:]
	}
}

func TestPerfettoLocalServerBoundary(t *testing.T) {
	dir := t.TempDir()
	id, origin := "abcdef", "http://127.0.0.1:9999"
	v := PFView{Schema: "gonka.view.v1", Fingerprint: id, Preset: "round", Height: 7}
	if err := artifactJSON(filepath.Join(dir, "view.json"), v); err != nil {
		t.Fatal(err)
	}
	a := PFAnalysis{Observations: []PFObservation{{ID: "allowed", Excerpt: "<script>unsafe()</script>"}}}
	h := perfettoHandler(origin, id, dir, a, fstest.MapFS{"test.wasm": {Data: []byte{0, 97, 115, 109}}, "index.html": {Data: []byte("local")}})
	body, _ := json.Marshal(v)
	for _, test := range []struct {
		path, method, host, origin, body string
		status                           int
	}{
		{"view", "GET", "127.0.0.1:9999", "", "", 200},
		{"view", "PUT", "127.0.0.1:9999", origin, string(body), 204},
		{"view", "PUT", "127.0.0.1:9999", "", string(body), 403},
		{"view", "GET", "attacker.example", "", "", 403},
		{"view", "GET", "127.0.0.1:9999", "http://attacker.example", "", 403},
		{"view", "PUT", "127.0.0.1:9999", origin, string(body) + "{}", 400},
		{"evidence/allowed", "GET", "127.0.0.1:9999", "", "", 200},
		{"evidence/etc/passwd", "GET", "127.0.0.1:9999", "", "", 404},
		{"analysis", "POST", "127.0.0.1:9999", origin, "", 405},
	} {
		r := httptest.NewRequest(test.method, origin+"/api/session/"+id+"/"+test.path, strings.NewReader(test.body))
		r.Host = test.host
		r.Header.Set("Origin", test.origin)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != test.status {
			t.Fatalf("%+v: %d %s", test, w.Code, w.Body.String())
		}
	}
	r := httptest.NewRequest("GET", origin+"/test.wasm", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/wasm" {
		t.Fatal(w.Code, w.Header())
	}
}

func TestPerfettoSavedIncident(t *testing.T) {
	for _, input := range []string{"incident-consensus.json", savedIncidentInput()} {
		t.Run(input, func(t *testing.T) {
			if _, err := os.Stat(input); err != nil {
				if os.Getenv("GONKACTL_TRACE_REQUIRE_SAMPLE") == "1" {
					t.Fatal(err)
				}
				t.Skip("retained sample not installed")
			}
			c, fp, kind, _, err := loadPerfettoInput(input)
			if err != nil {
				t.Fatal(err)
			}
			a := makeAnalysis(c, fp, kind)
			for _, e := range a.Events {
				if e.TraceNS != "" && (strings.HasPrefix(e.ActorID, "core@node2/") || strings.HasPrefix(e.ActorID, "core@node5/")) {
					t.Fatal("RPC evidence became historical core state", e)
				}
			}
			removed, added := false, false
			for _, change := range a.Changes {
				if strings.HasPrefix(change.ValidatorID, "27FA1535F3F7") && change.OldPower != nil {
					removed = removed || (change.Height == 306513 && *change.OldPower == 70 && *change.NewPower == 0)
					added = added || (change.Height == 306553 && *change.NewPower == 54)
				}
			}
			if !removed || !added {
				t.Fatal("membership history lost", removed, added)
			}
			variants := map[int64]bool{}
			for _, cert := range a.Certificates {
				if cert.Height == 306552 {
					if cert.Power == nil {
						t.Fatal("unexpected incomplete certificate")
					}
					variants[*cert.Power] = true
				}
			}
			if len(variants) != 3 || !variants[283] || !variants[284] || !variants[405] {
				t.Fatal(variants)
			}
			snapshots := 0
			for _, r := range a.Rounds {
				if r.Height == 306553 && r.Round == 0 && r.Temporality == "snapshot" {
					snapshots++
					for _, v := range r.Tallies {
						if v.Type == "PREVOTE" && v.Target == "any" {
							if v.Power == nil || *v.Power != 81 || *v.Quorum != 91 || *v.Deficit != 10 || *v.Unrepresented != 54 {
								t.Fatal(r.Observer, v)
							}
						}
					}
				}
			}
			if snapshots != 5 {
				t.Fatal("snapshot observers", snapshots)
			}
			points := []PFMeasurement{}
			for _, m := range a.Measurements {
				if m.Height == 306553 && m.Type == "PREVOTE" && m.TraceNS != "" {
					points = append(points, m)
				}
			}
			if len(points) != 2 || *points[0].Value != 54 || *points[1].Value != 81 || !timestamp(points[0].AsOf).Before(timestamp(points[1].AsOf)) {
				t.Fatal("signing points", points)
			}
		})
	}
}

func TestPerfettoCLIStateAndCache(t *testing.T) {
	c := fixtureConsensus()
	c.Incident = "synthetic-cache-test"
	c.Start = timestamp("2026-01-01T00:00:00Z")
	c.End = c.Start.Add(time.Second)
	c.height(7).HeaderTime = c.Start
	c.height(7).BlockID = strings.Repeat("F", 64)
	trace, err := consensusTrace(c, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := marshalTrace(trace)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	input := filepath.Join(dir, "input.json")
	if err = os.WriteFile(input, b, 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--input", input, "--export-only"}
	if err = runPerfetto(args); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, ".gonka-perfetto", "input.json")
	path := filepath.Join(out, "analysis.json")
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	var view PFView
	vbytes, _ := os.ReadFile(filepath.Join(out, "view.json"))
	if err = json.Unmarshal(vbytes, &view); err != nil {
		t.Fatal(err)
	}
	view.Preset = "membership"
	view.Height = 306513
	view.Viewport = []string{"10", "20"}
	if err = artifactJSON(filepath.Join(out, "view.json"), view); err != nil {
		t.Fatal(err)
	}
	if err = runPerfetto(append(args, "--port", "31415")); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(path)
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("compatible analysis cache rewritten")
	}
	vbytes, _ = os.ReadFile(filepath.Join(out, "view.json"))
	var saved PFView
	_ = json.Unmarshal(vbytes, &saved)
	if saved.Preset != "membership" || saved.Height != 306513 || len(saved.Viewport) != 2 {
		t.Fatal("state lost across port change", saved)
	}
	// A changed input cannot retain another dataset's viewport.
	if err = os.WriteFile(input, append(b, ' '), 0600); err != nil {
		t.Fatal(err)
	}
	if err = runPerfetto(args); err != nil {
		t.Fatal(err)
	}
	vbytes, _ = os.ReadFile(filepath.Join(out, "view.json"))
	_ = json.Unmarshal(vbytes, &saved)
	if saved.Fingerprint == view.Fingerprint || saved.Preset != "overview" {
		t.Fatal("incompatible state reused")
	}
}

func TestPerfettoIntervalsAndApplicationFailure(t *testing.T) {
	c := fixtureConsensus()
	c.Start = timestamp("2026-09-09T00:00:00Z")
	c.End = c.Start.Add(10 * time.Second)
	for i, phase := range []string{"PREVOTE", "PRECOMMIT", "PREVOTE"} {
		c.add(ConsensusObservation{Height: 7, Round: 0, Observer: "n1", Phase: phase, Kind: "state." + strings.ToLower(phase), Time: c.Start.Add(time.Duration(i) * time.Second), Source: "core.log#" + phase})
	}
	c.readEvents([]Event{{Node: "n1", Component: "core", Time: c.End, Message: "failed FinalizeBlock height=7 module=state", Source: "app-error"}})
	a := makeAnalysis(c, "fixture", "sample")
	if len(a.Intervals) != 1 || a.Intervals[0].Phase != "PREVOTE" {
		t.Fatal("state regression or invented interval", a.Intervals)
	}
	if !strings.Contains(strings.Join(a.Findings, " "), "application failure") {
		t.Fatal("application error hidden as quorum loss")
	}
}

func TestPerfettoEmbeddedAssets(t *testing.T) {
	b, err := perfettoAssets.ReadFile("ui-dist/asset-manifest.json")
	if err != nil {
		if os.Getenv("GONKACTL_TRACE_REQUIRE_UI") == "1" {
			t.Fatal("offline release assets required", err)
		}
		t.Skip("development build without offline assets")
	}
	var manifest struct {
		Files []struct {
			Path  string `json:"path"`
			SHA   string `json:"sha256"`
			Bytes int    `json:"bytes"`
		} `json:"files"`
	}
	if err = json.Unmarshal(b, &manifest); err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{}
	wasm, plugin := false, false
	for _, file := range manifest.Files {
		path := "ui-dist/" + file.Path
		data, err := perfettoAssets.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(data)
		if hex.EncodeToString(hash[:]) != file.SHA || len(data) != file.Bytes {
			t.Fatal("embedded asset differs", file.Path)
		}
		known[path] = true
		wasm = wasm || strings.HasSuffix(file.Path, ".wasm") && len(data) > 4 && bytes.Equal(data[:4], []byte{0, 97, 115, 109})
		plugin = plugin || strings.HasSuffix(file.Path, ".js") && bytes.Contains(data, []byte("net.gonka.Consensus"))
	}
	if !wasm || !plugin || !known["ui-dist/index.html"] {
		t.Fatal("incomplete offline release", wasm, plugin)
	}
	if err = fs.WalkDir(perfettoAssets, "ui-dist", func(path string, entry fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !entry.IsDir() && path != "ui-dist/asset-manifest.json" && !known[path] {
			t.Errorf("unmanifested asset %s", path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
