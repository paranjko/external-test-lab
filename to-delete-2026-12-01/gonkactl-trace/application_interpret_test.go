package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInterpretApplication(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "page.json")
	if err := os.WriteFile(source, []byte(`{"members":[],"pagination":{"next_key":null}}`), 0600); err != nil {
		t.Fatal(err)
	}
	d := Dataset{Config: Config{Incident: "incident", Chain: "chain", ApplicationRequests: []ApplicationRequest{{Node: "node0", Height: 10, Path: "/cosmos/group/v1/group_members/1", Paginated: true}}}, Receipts: []Receipt{{Node: "node0", Path: ".gonkactl-trace/sample/page.json", Source: "https://example.test/chain-api/cosmos/group/v1/group_members/1?pagination.limit=100", Application: &ApplicationEvidence{RequestedHeight: 10, ReportedHeight: "10", Page: 1, Complete: true}}}}
	p := filepath.Join(dir, "dataset.json")
	if err := writeJSON(p, d); err != nil {
		t.Fatal(err)
	}
	r, err := interpretApplication([]string{p})
	if err != nil || r.Queries[0].Status != "reported" || len(r.Queries[0].Digests) != 1 {
		t.Fatalf("%+v %v", r, err)
	}
	d.Receipts[0].Application.ReportedHeight = "11"
	writeJSON(p, d)
	r, err = interpretApplication([]string{p})
	if err != nil || r.Queries[0].Status != "gap" || len(r.Queries[0].Pages) != 0 {
		t.Fatal("height mismatch accepted")
	}
	d.Receipts = nil
	writeJSON(p, d)
	r, err = interpretApplication([]string{p})
	if err != nil || r.Queries[0].Error == "" {
		t.Fatal("missing receipt accepted")
	}
}
