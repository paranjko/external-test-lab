package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/collector/pdata/ptrace"
	tracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/protobuf/proto"
)

func TestVoteMetrics(t *testing.T) {
	r := int64(0)
	e := Event{Node: "node1", Height: 12, Round: &r, Type: "consensus.prevote", Attr: map[string]string{"votes.bit_array": "BA{3:_xx} 81/135 = 0.60"}}
	m := voteMetrics(e, map[string]int64{"node1/12": 135})
	if m["quorum"] != int64(91) || m["deficit"] != int64(10) || m["status"] != "complete_snapshot" {
		t.Fatal(m)
	}
	if voteMetrics(e, nil)["status"] != "partial" {
		t.Fatal("missing validator set became complete")
	}
	e.Attr["votes.bit_array"] = "BA{3:___} 0/135 = 0"
	e.Type = "consensus.precommit"
	if voteMetrics(e, nil)["deficit"] != int64(91) {
		t.Fatal("prevotes treated as precommits")
	}
}
func TestLogNormalization(t *testing.T) {
	s := "2026-09-09T18:59:33.001Z ERROR signer failed height=306553 round=0 api_key=ctxio_PRIVATE\n2026-09-09T18:59:34Z INFO received prevote height=306553 round=1\nno timestamp height=306552"
	e := normalizeLog(s, "node5", "core", "log", 306500, 306552, time.Time{}, time.Time{}, false)
	if len(e) != 3 || e[0].Type != "signer.error" || e[1].Type != "consensus.prevote" || strings.Contains(e[0].Message, "PRIVATE") {
		t.Fatal(e)
	}
	d := Dataset{Collected: time.Now(), Events: e}
	d.Events = append(d.Events, Event{Type: "block.commit", Height: 306552, Time: timestamp("2026-09-09T18:59:22Z")})
	inferTimes(&d)
	for _, e := range d.Events {
		if e.Message == "no timestamp height=306552" && (!e.Inferred || e.Time.IsZero()) {
			t.Fatal(e)
		}
	}
}
func TestTraceJSONAndReplay(t *testing.T) {
	a := timestamp("2026-09-09T18:59:22Z")
	d := Dataset{Config: Config{Incident: "test", Chain: "test"}, Collected: a.Add(24 * time.Hour), Events: []Event{{Time: a, OriginalTimestamp: a.Format(time.RFC3339Nano), Node: "node1", Type: "block.commit", Height: 1}, {Time: a.Add(time.Second), Node: "node1", Type: "log", Height: 1}, {Time: a.Add(24 * time.Hour), Node: "node1", Type: "rpc.status", Current: true}}}
	original, err := buildTrace(d, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := marshalTrace(original)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]any
	if json.Unmarshal(b, &wire) != nil {
		t.Fatal("invalid JSON")
	}
	if _, err = (&ptrace.JSONUnmarshaler{}).UnmarshalTraces(b); err != nil {
		t.Fatal(err)
	}
	for _, r := range list(wire["resourceSpans"]) {
		for _, scope := range list(object(r)["scopeSpans"]) {
			for _, s := range list(object(scope)["spans"]) {
				m := object(s)
				if len(str(m["traceId"])) != 32 || len(str(m["spanId"])) != 16 {
					t.Fatal(m)
				}
				if _, ok := m["startTimeUnixNano"].(string); !ok {
					t.Fatal("timestamp not string")
				}
			}
		}
	}
	replay, err := buildTrace(d, time.Hour, "unique")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < original.ResourceSpans().Len(); i++ {
		os := original.ResourceSpans().At(i).ScopeSpans().At(0).Spans()
		rs := replay.ResourceSpans().At(i).ScopeSpans().At(0).Spans()
		for j := 0; j < os.Len(); j++ {
			delta := rs.At(j).StartTimestamp().AsTime().Sub(os.At(j).StartTimestamp().AsTime())
			expected := time.Hour
			if i == 1 {
				expected = 0
			}
			if delta != expected {
				t.Fatalf("shift %v expected %v", delta, expected)
			}
			if rs.At(j).TraceID() == os.At(j).TraceID() {
				t.Fatal("replay reused trace ID")
			}
		}
	}
}
func TestPaginationAndIsolation(t *testing.T) {
	pages := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pages++
		page := r.URL.Query().Get("page")
		addr := "A"
		if page == "2" {
			addr = "B"
		}
		fmt.Fprintf(w, `{"result":{"block_height":"7","total":"2","validators":[{"address":%q,"voting_power":"10"}]}}`, addr)
	}))
	defer s.Close()
	x := collector{dir: t.TempDir(), client: s.Client()}
	x.rpc(Node{ID: "node1", RPC: s.URL}, "validators", 7)
	if pages != 2 || len(x.d.Receipts) != 2 || len(x.d.Events) != 1 || x.d.Events[0].Attr["voting_power.total"] != "20" {
		t.Fatal(x.d)
	}
	x.rpc(Node{ID: "bad", RPC: ":invalid"}, "block", 7)
	if len(x.d.Events) != 1 || x.d.Receipts[2].Error == "" {
		t.Fatal("source failure discarded prior evidence")
	}
}
func TestRedactionAndLogPath(t *testing.T) {
	for _, s := range []string{`{"api_key":"top-secret"}`, "Authorization: Bearer top-secret", "password=top-secret", "-----BEGIN PRIVATE KEY-----\ntop-secret\n-----END PRIVATE KEY-----"} {
		if strings.Contains(redact(s), "top-secret") {
			t.Fatal(redact(s))
		}
	}
	for _, p := range []string{"priv_validator_key.json", "/root/.env", "/root/secret.log"} {
		if safeLogPath(p) {
			t.Fatal(p)
		}
	}
	b := &boundedBuffer{limit: 3}
	n, e := b.Write([]byte("abcde"))
	if n != 5 || e != nil || string(b.b) != "abc" || !b.overflow {
		t.Fatal(b)
	}
}
func TestNoKeyNoSend(t *testing.T) {
	t.Setenv("TRACEKIT_API_KEY", "")
	if e := replay(Dataset{}); e == nil || !strings.Contains(e.Error(), "TRACEKIT_API_KEY") {
		t.Fatal(e)
	}
}
func TestSavePermissions(t *testing.T) {
	p := filepath.Join(t.TempDir(), "sample.json")
	if e := writeJSON(p, map[string]int{"a": 1}); e != nil {
		t.Fatal(e)
	}
	s, e := os.Stat(p)
	if e != nil || s.Mode().Perm() != 0600 {
		t.Fatal(s, e)
	}
}

func TestTMKMSHeightRoundAndOriginalTimes(t *testing.T) {
	es := normalizeLog("2026-09-09T18:52:32.793592115Z 2026-09-09T18:52:32.793282Z INFO tmkms::session: signed PreVote:<nil> at h/r/s 306480/0/1 (0 ms)", "node1", "tmkms", "log", 306500, 306552, time.Time{}, time.Time{}, false)
	if len(es) != 1 || es[0].Height != 306480 || es[0].Round == nil || *es[0].Round != 0 || es[0].Attr["component.original_timestamp"] == "" {
		t.Fatal(es)
	}
}
func TestVisualizerSingleRoot(t *testing.T) {
	a := time.Now().UTC()
	d := Dataset{Collected: a, Events: []Event{{Time: a, Type: "block.commit", Node: "n", Height: 1}, {Time: a.Add(time.Hour), Type: "rpc.status", Node: "n", Current: true}}}
	all, e := buildTrace(d, 0, "")
	if e != nil {
		t.Fatal(e)
	}
	historical, current := splitTrace(all)
	if historical.SpanCount()+current.SpanCount() != all.SpanCount() || current.SpanCount() == 0 {
		t.Fatal("split lost spans")
	}
	for _, trace := range []ptrace.Traces{historical, current} {
		roots := 0
		ids := map[string]bool{}
		parents := []string{}
		for i := 0; i < trace.ResourceSpans().Len(); i++ {
			ss := trace.ResourceSpans().At(i).ScopeSpans().At(0).Spans()
			for j := 0; j < ss.Len(); j++ {
				s := ss.At(j)
				ids[s.SpanID().String()] = true
				if s.ParentSpanID().IsEmpty() {
					roots++
				} else {
					parents = append(parents, s.ParentSpanID().String())
				}
			}
		}
		if roots != 1 {
			t.Fatal("visualizer requires one root")
		}
		for _, p := range parents {
			if !ids[p] {
				t.Fatal("orphan span")
			}
		}
	}
}
func TestUnanchoredDoesNotStretchHistory(t *testing.T) {
	historical := timestamp("2026-09-09T18:59:22Z")
	d := Dataset{Collected: historical.Add(24 * time.Hour), Events: []Event{{Time: historical, Type: "block.commit", Height: 1, Source: "block"}, {Type: "log", Source: "unrelated.log#L1", Message: "old deploy output"}}}
	inferTimes(&d)
	e := d.Events[1]
	if !e.Current || !e.Inferred || !e.Time.Equal(d.Collected) {
		t.Fatal(e)
	}
}

func TestOTLPProtobufCompatibility(t *testing.T) {
	d := Dataset{Collected: time.Now().UTC(), Events: []Event{{Time: time.Now().UTC(), Type: "block.commit", Node: "node1"}}}
	tr, e := buildTrace(d, 0, "")
	if e != nil {
		t.Fatal(e)
	}
	wire, e := (&ptrace.ProtoMarshaler{}).MarshalTraces(tr)
	if e != nil {
		t.Fatal(e)
	}
	request := &tracepb.ExportTraceServiceRequest{}
	if e = proto.Unmarshal(wire, request); e != nil {
		t.Fatal(e)
	}
	if len(request.ResourceSpans) != 1 || len(request.ResourceSpans[0].ScopeSpans[0].Spans) != tr.SpanCount() {
		t.Fatal("pdata/exporter protobuf mismatch")
	}
}
func TestFailedLogIsNotAnIncidentEvent(t *testing.T) {
	d := Dataset{Collected: time.Now().UTC(), Receipts: []Receipt{{Node: "node5", Source: "file:register-participant.log", Path: "missing", Bytes: 99, Error: "exit status 1"}}}
	if e := rebuildEvents(&d); e != nil {
		t.Fatal(e)
	}
	if len(d.Events) != 0 {
		t.Fatal("collector failure became JOIN event")
	}
}
