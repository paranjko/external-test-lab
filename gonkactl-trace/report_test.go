package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReportPipelineOfflineReproduction(t *testing.T) {
	t.Chdir(t.TempDir())
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.URL.Query().Get("height")
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/block":
			fmt.Fprintf(w, `{"result":{"block_id":{"hash":"%s"},"block":{"header":{"height":"%s","chain_id":"test","time":"2026-09-09T18:59:00Z"}}}}`, strings.Repeat("A", 64), h)
		case "/validators":
			fmt.Fprintf(w, `{"result":{"block_height":"%s","validators":[],"total":"0"}}`, h)
		case "/status":
			fmt.Fprint(w, `{"result":{"sync_info":{"latest_block_height":"52"}}}`)
		default:
			fmt.Fprint(w, `{"result":{}}`)
		}
	}))
	c := Config{Incident: "test", Chain: "test", Nodes: []Node{{ID: "node0", RPC: s.URL}}, Concurrency: 1, TimeoutSeconds: 2}
	if err := writeJSON("gonkactl-trace.json", c); err != nil {
		t.Fatal(err)
	}
	if err := runReport([]string{"50"}); err != nil {
		t.Fatal(err)
	}
	s.Close() // Offline reproduction must work with all sources unreachable.
	paths, err := filepath.Glob(".gonkactl-trace/sample-*/dataset.json")
	if err != nil || len(paths) != 1 {
		t.Fatal(paths, err)
	}
	manifests, _ := filepath.Glob(".gonkactl-trace/sample-*/derived/perfetto/application-*/report-manifest.json")
	if len(manifests) != 1 {
		t.Fatal(manifests)
	}
	dir := filepath.Dir(manifests[0])
	before := map[string][]byte{}
	for _, name := range []string{"report.html", "matrix.json", "analysis.json", "incident.pftrace", "report-manifest.json"} {
		b, e := os.ReadFile(filepath.Join(dir, name))
		if e != nil {
			t.Fatal(e)
		}
		before[name] = b
	}
	if err = runReport([]string{"--input", paths[0]}); err != nil {
		t.Fatal(err)
	}
	for name, b := range before {
		after, e := os.ReadFile(filepath.Join(dir, name))
		if e != nil || !bytes.Equal(b, after) {
			t.Fatalf("non-reproducible %s: %v", name, e)
		}
	}
	// Rebuild from relocated raw inputs, with no derived cache to reuse.
	relocated := filepath.Join(t.TempDir(), "sample")
	if err = os.Mkdir(relocated, 0700); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Dir(paths[0]))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		b, e := os.ReadFile(filepath.Join(filepath.Dir(paths[0]), entry.Name()))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(relocated, entry.Name()), b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	if err = runReport([]string{"--input", relocated}); err != nil {
		t.Fatal(err)
	}
	rebuilt, _ := filepath.Glob(filepath.Join(relocated, "derived/perfetto/application-*/report-manifest.json"))
	if len(rebuilt) != 1 {
		t.Fatal(rebuilt)
	}
	for name, b := range before {
		after, e := os.ReadFile(filepath.Join(filepath.Dir(rebuilt[0]), name))
		if e != nil || !bytes.Equal(b, after) {
			t.Fatalf("cold relocated reproduction differs: %s %v", name, e)
		}
	}
	var m PFMatrix
	if err = json.Unmarshal(before["matrix.json"], &m); err != nil || m.To < 50 || m.To > 53 {
		t.Fatalf("wrong report interval: %+v %v", m.Meta, err)
	}
	if strings.Contains(string(before["report.html"]), `src="/gonka/`) {
		t.Fatal("HTML requires a live server")
	}
}

func TestStandaloneHTMLSafeAndDeterministic(t *testing.T) {
	m := PFMatrix{Findings: []string{`</script><script>alert('x')</script>`}}
	a, err := standaloneHTML(m)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := standaloneHTML(m)
	if !bytes.Equal(a, b) || bytes.Contains(a, []byte(m.Findings[0])) {
		t.Fatal("unstable or executable source content")
	}
	if !bytes.Contains(a, []byte(`id="gonka-report-data"`)) {
		t.Fatal("missing embedded source projection")
	}
}

func TestReportArguments(t *testing.T) {
	for _, args := range [][]string{{}, {"0"}, {"5", "4"}, {"1", "9223372036854775807"}, {"--input", "x", "5"}, {"--bogus"}} {
		if err := runReport(args); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}

func TestDiscoverApplicationUsesReportedIdentifiers(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		t.Run(fmt.Sprint(mismatch), func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				h := r.Header.Get("x-cosmos-block-height")
				if mismatch {
					h = "999"
				}
				w.Header().Set("x-cosmos-block-height", h)
				switch r.URL.Path {
				case inferencePrefix + "params":
					fmt.Fprint(w, `{"params":{"epoch_params":{"poc_stage_duration":"4","poc_validation_delay":"10","poc_validation_duration":"4"}}}`)
				case inferencePrefix + "current_epoch_group_data":
					fmt.Fprint(w, `{"epoch_group_data":{"poc_start_block_height":"30","epoch_index":"9","epoch_group_id":"19"}}`)
				default:
					fmt.Fprint(w, `{"pagination":{"next_key":null}}`)
				}
			}))
			defer s.Close()
			x := collector{dir: t.TempDir(), client: s.Client(), d: Dataset{From: 20, To: 52, Config: Config{Nodes: []Node{{ID: "node0", REST: s.URL}}}}}
			if err := x.discoverApplication(); err != nil {
				t.Fatal(err)
			}
			found := false
			for _, r := range x.d.Config.ApplicationRequests {
				if r.Height < 20 || r.Height > 52 {
					t.Fatal("query outside requested range")
				}
				if r.Path == inferencePrefix+"poc_validation_snapshot/30" && r.Height == 44 {
					found = true
				}
			}
			if found == mismatch {
				t.Fatalf("discovery used unverified state or missed derived snapshot: %+v", x.d.Config.ApplicationRequests)
			}
		})
	}
}
