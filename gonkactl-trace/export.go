package main

import "go.opentelemetry.io/collector/pdata/ptrace"

// The free visualizer walks a single root; keep independent timelines in separate files.
func splitTrace(t ptrace.Traces) (ptrace.Traces, ptrace.Traces) {
	historical, current := ptrace.NewTraces(), ptrace.NewTraces()
	for i := 0; i < t.ResourceSpans().Len(); i++ {
		r := t.ResourceSpans().At(i)
		v, _ := r.Resource().Attributes().Get("current_observation")
		dest := historical
		if v.Bool() {
			dest = current
		}
		r.CopyTo(dest.ResourceSpans().AppendEmpty())
	}
	return historical, current
}
