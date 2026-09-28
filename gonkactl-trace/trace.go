package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	tracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/protobuf/proto"
)

func traceID(s string) pcommon.TraceID {
	h := sha256.Sum256([]byte(s))
	var id pcommon.TraceID
	copy(id[:], h[:16])
	return id
}
func spanID(s string) pcommon.SpanID {
	h := sha256.Sum256([]byte(s))
	var id pcommon.SpanID
	copy(id[:], h[:8])
	return id
}
func attrs(m pcommon.Map, values map[string]string) {
	keys := []string{}
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		m.PutStr(k, redact(values[k]))
	}
}
func bounds(events []Event) (time.Time, time.Time) {
	var a, b time.Time
	for _, e := range events {
		if a.IsZero() || e.Time.Before(a) {
			a = e.Time
		}
		if e.Time.After(b) {
			b = e.Time
		}
	}
	return a, b.Add(time.Millisecond)
}
func buildTrace(d Dataset, shift time.Duration, replayID string) (ptrace.Traces, error) {
	t := ptrace.NewTraces()
	if len(d.Events) == 0 {
		return t, fmt.Errorf("no events collected")
	}
	sets := map[string]int64{}
	for _, e := range d.Events {
		if e.Type == "validators.set" {
			sets[fmt.Sprintf("%s/%d", e.Node, e.Height)] = number(e.Attr["voting_power.total"])
		}
	}
	for _, current := range []bool{false, true} {
		events := []Event{}
		for _, e := range d.Events {
			if e.Current == current {
				events = append(events, e)
			}
		}
		if len(events) == 0 {
			continue
		}
		a, b := bounds(events)
		offset := shift
		if current {
			offset = 0
		}
		category := "incident"
		if current {
			category = "current-observations"
		}
		seed := d.Config.Incident + "/" + d.Collected.Format(time.RFC3339Nano) + "/" + category + "/" + replayID
		tid := traceID(seed)
		rs := t.ResourceSpans().AppendEmpty()
		attrs(rs.Resource().Attributes(), map[string]string{"service.name": "gonkactl-trace", "incident.id": d.Config.Incident, "chain.id": d.Config.Chain, "telemetry.mode": "historical-reconstruction"})
		rs.Resource().Attributes().PutBool("current_observation", current)
		ss := rs.ScopeSpans().AppendEmpty()
		ss.Scope().SetName("gonkactl-trace/reconstruction")
		spans := ss.Spans()
		makeSpan := func(name, key string, parent pcommon.SpanID, start, end time.Time) ptrace.Span {
			s := spans.AppendEmpty()
			s.SetTraceID(tid)
			s.SetSpanID(spanID(seed + key))
			s.SetParentSpanID(parent)
			s.SetName(name)
			s.SetKind(ptrace.SpanKindInternal)
			s.SetStartTimestamp(pcommon.NewTimestampFromTime(start.Add(offset)))
			s.SetEndTimestamp(pcommon.NewTimestampFromTime(end.Add(offset)))
			s.Attributes().PutBool("reconstructed", true)
			s.Attributes().PutStr("reconstruction.description", "analytical grouping, not an instrumented operation")
			s.Attributes().PutBool("current_observation", current)
			attrs(s.Attributes(), map[string]string{"original_start": start.Format(time.RFC3339Nano), "original_end": end.Format(time.RFC3339Nano), "correlation.basis": "analytical grouping, not causal proof"})
			if replayID != "" {
				s.Attributes().PutBool("replay", true)
				s.Attributes().PutStr("replay_id", replayID)
			}
			return s
		}
		root := makeSpan(category+" "+d.Config.Incident, "root", pcommon.SpanID{}, a, b)
		root.Attributes().PutStr("node.id", "all")
		summary, _ := json.Marshal(summarize(d))
		root.Attributes().PutStr("analysis.summary", string(summary))
		groups := map[string][]Event{}
		for _, e := range events {
			phase := fmt.Sprintf("height %d", e.Height)
			if e.Height == 0 {
				phase = "unassigned phase"
			}
			groups[phase] = append(groups[phase], e)
		}
		keys := []string{}
		for k := range groups {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, key := range keys {
			es := groups[key]
			ga, gb := bounds(es)
			phase := makeSpan(key, key, root.SpanID(), ga, gb)
			phase.Attributes().PutStr("node.id", "all")
			nodes := map[string][]Event{}
			for _, e := range es {
				nodes[e.Node] = append(nodes[e.Node], e)
			}
			nk := []string{}
			for n := range nodes {
				nk = append(nk, n)
			}
			sort.Strings(nk)
			for _, n := range nk {
				ns := nodes[n]
				na, nb := bounds(ns)
				nodeSpan := makeSpan(n, key+"/"+n, phase.SpanID(), na, nb)
				nodeSpan.Attributes().PutStr("node.id", n)
				for i, e := range ns {
					values := map[string]string{"node.id": e.Node, "component": e.Component, "source.record": e.Source, "message": e.Message, "original_timestamp": e.OriginalTimestamp, "height": strconv.FormatInt(e.Height, 10)}
					for k, v := range e.Attr {
						values[k] = v
					}
					if e.Round != nil {
						values["round"] = strconv.FormatInt(*e.Round, 10)
					}
					if _, ok := e.Attr["votes.bit_array"]; ok {
						m, _ := json.Marshal(voteMetrics(e, sets))
						values["voting_power.analysis"] = string(m)
					}
					se := nodeSpan.Events().AppendEmpty()
					se.SetName(e.Type)
					se.SetTimestamp(pcommon.NewTimestampFromTime(e.Time.Add(offset)))
					attrs(se.Attributes(), values)
					se.Attributes().PutBool("time_inferred", e.Inferred)
					if e.Type != "log" {
						s := makeSpan(e.Type, fmt.Sprintf("%s/%s/%d", key, n, i), nodeSpan.SpanID(), e.Time, e.Time.Add(time.Millisecond))
						attrs(s.Attributes(), values)
						s.Attributes().PutBool("time_inferred", e.Inferred)
						s.Attributes().PutStr("display_duration", "1ms; not measured operation duration")
					}
				}
			}
		}
	}
	return t, nil
}
func marshalTrace(t ptrace.Traces) ([]byte, error) { return (&ptrace.JSONMarshaler{}).MarshalTraces(t) }
func replay(d Dataset) error {
	var latest time.Time
	for _, e := range d.Events {
		if !e.Current && e.Time.After(latest) {
			latest = e.Time
		}
	}
	return replayProjection(latest, func(shift time.Duration, id string) (ptrace.Traces, error) { return buildTrace(d, shift, id) })
}
func replayProjection(latest time.Time, build func(time.Duration, string) (ptrace.Traces, error)) error {
	key := os.Getenv("TRACEKIT_API_KEY")
	if key == "" {
		return fmt.Errorf("TRACEKIT_API_KEY is missing; collect and otlp remain available")
	}
	if latest.IsZero() {
		return fmt.Errorf("no historical timestamps to replay")
	}
	id := make([]byte, 16)
	if _, e := rand.Read(id); e != nil {
		return e
	}
	rid := hex.EncodeToString(id)
	t, e := build(time.Now().UTC().Add(-5*time.Second).Sub(latest.Add(time.Millisecond)), rid)
	if e != nil {
		return e
	}
	b, e := (&ptrace.ProtoMarshaler{}).MarshalTraces(t)
	if e != nil {
		return e
	}
	request := &tracepb.ExportTraceServiceRequest{}
	if e = proto.Unmarshal(b, request); e != nil {
		return e
	}
	client := otlptracehttp.NewClient(otlptracehttp.WithEndpointURL("https://app.tracekit.dev/v1/traces"), otlptracehttp.WithHeaders(map[string]string{"X-API-Key": key}), otlptracehttp.WithTimeout(30*time.Second))
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	if e = client.Start(ctx); e != nil {
		return e
	}
	defer client.Stop(context.Background())
	ids := []string{}
	spans, events := 0, 0
	for _, r := range request.ResourceSpans {
		for _, s := range r.ScopeSpans {
			if len(s.Spans) > 0 {
				ids = append(ids, hex.EncodeToString(s.Spans[0].TraceId))
			}
			for _, p := range s.Spans {
				spans++
				events += len(p.Events)
			}
		}
	}
	e = client.UploadTraces(ctx, request.ResourceSpans)
	fmt.Fprintf(os.Stderr, "replay_id=%s traces=%d spans=%d events=%d trace_ids=%v\n", rid, len(ids), spans, events, ids)
	if e != nil {
		return fmt.Errorf("OTLP send failed: %s", redact(e.Error()))
	}
	fmt.Fprintln(os.Stderr, "OTLP accepted; dashboard visibility not verified: https://app.tracekit.dev/traces")
	return nil
}
