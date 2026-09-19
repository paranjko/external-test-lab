package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"google.golang.org/protobuf/encoding/protowire"
	"sort"
	"strconv"
)

// Native TrackEvent wire schema pinned with the UI in perfetto-build.json.
// Unused fields remain absent. This is protobuf, not Chrome Trace JSON.
func pbUint(b []byte, n protowire.Number, v uint64) []byte {
	return protowire.AppendVarint(protowire.AppendTag(b, n, protowire.VarintType), v)
}
func pbBytes(b []byte, n protowire.Number, v []byte) []byte {
	return protowire.AppendBytes(protowire.AppendTag(b, n, protowire.BytesType), v)
}
func pbString(b []byte, n protowire.Number, v string) []byte { return pbBytes(b, n, []byte(v)) }
func trackUUID(s string) uint64 {
	h := sha256.Sum256([]byte(s))
	return binary.LittleEndian.Uint64(h[:8]) | 1
}
func pfAnnotation(name, value string) []byte { return pbString(pbString(nil, 10, name), 6, value) }
func nativePerfetto(a PFAnalysis) []byte {
	var out []byte
	type timedPacket struct {
		ts    uint64
		bytes []byte
	}
	packets := []timedPacket{}
	packet := func(ts uint64, field protowire.Number, body []byte) {
		p := pbUint(nil, 8, ts)
		p = pbUint(p, 10, 1)
		p = pbUint(p, 58, 6)
		p = pbBytes(p, field, body)
		packets = append(packets, timedPacket{ts, p})
	}
	tracks := map[string]bool{}
	labels := map[string]string{}
	participants := map[string]string{}
	for _, actor := range a.Actors {
		labels[actor.ID] = actor.Label
		participants["gonka/"+actor.ID] = actor.Participant
		participants["gonka/power/"+actor.ID] = actor.Participant
		participants["gonka/interval/"+actor.ID] = actor.Participant
	}
	descriptor := func(id, name string, counter bool) {
		if tracks[id] {
			return
		}
		d := pbUint(nil, 1, trackUUID(id))
		d = pbString(d, 2, name)
		d = pbUint(d, 9, 1)
		if participant := participants[id]; participant != "" {
			parent := "gonka/participant/" + participant
			if !tracks[parent] {
				p := pbString(pbUint(nil, 1, trackUUID(parent)), 2, participant)
				packet(0, 60, p)
				tracks[parent] = true
			}
			d = pbUint(d, 5, trackUUID(parent))
		}
		if counter {
			d = pbBytes(d, 8, pbString(nil, 7, "gonka.power"))
		}
		packet(0, 60, d)
		tracks[id] = true
	}
	emit := func(ts uint64, track, name string, kind uint64, values map[string]string, counter *int64) {
		e := pbUint(nil, 9, kind)
		e = pbUint(e, 11, trackUUID(track))
		if name != "" {
			e = pbString(e, 23, name)
		}
		if counter != nil {
			e = pbUint(e, 30, uint64(*counter))
		}
		for _, k := range sortedKeys(values) {
			e = pbBytes(e, 4, pfAnnotation(k, values[k]))
		}
		packet(ts, 11, e)
	}
	descriptor("gonka/metadata", "Gonka / metadata", false)
	emit(0, "gonka/metadata", "Gonka incident metadata", 3, map[string]string{"gonka.schema": a.Meta.Schema, "gonka.fingerprint": a.Meta.Fingerprint, "gonka.utc_origin": a.Meta.Origin}, nil)
	events := append([]PFEvent(nil), a.Events...)
	sort.SliceStable(events, func(i, j int) bool {
		x, _ := strconv.ParseInt(events[i].TraceNS, 10, 64)
		y, _ := strconv.ParseInt(events[j].TraceNS, 10, 64)
		if x == y {
			return events[i].ID < events[j].ID
		}
		return x < y
	})
	for _, e := range events {
		if e.TraceNS == "" || e.Temporality != "historical" {
			continue
		}
		ts, err := strconv.ParseInt(e.TraceNS, 10, 64)
		if err != nil || ts < 0 {
			continue
		}
		track := "gonka/" + e.ActorID
		label := labels[e.ActorID]
		if label == "" {
			label = e.ActorID
		}
		descriptor(track, label, false)
		values := map[string]string{"gonka.event_id": e.ID, "gonka.actor_id": e.ActorID, "gonka.observer_id": e.ObserverID, "gonka.phase": e.Phase, "gonka.evidence_kind": e.Kind, "gonka.time_basis": e.TimeBasis, "gonka.original_timestamp": e.OccurredAt}
		if e.ValidatorID != nil {
			values["gonka.validator_id"] = *e.ValidatorID
		}
		if len(e.SourceRefs) > 0 {
			values["gonka.source_ref"] = e.SourceRefs[0]
		}
		te := pbUint(nil, 9, 3)
		te = pbUint(te, 11, trackUUID(track))
		te = pbString(te, 23, fmt.Sprintf("H%d R%d %s %s", e.Height, e.Round, e.Phase, e.Kind))
		for _, relation := range a.Intervals {
			field := protowire.Number(0)
			if relation.FromEvent == e.ID {
				field = 47
			}
			if relation.ToEvent == e.ID {
				field = 48
			}
			if field != 0 {
				te = protowire.AppendFixed64(protowire.AppendTag(te, field, protowire.Fixed64Type), trackUUID(relation.ID))
				te = pbBytes(te, 4, pfAnnotation("gonka.flow_basis", relation.Basis))
			}
		}
		for _, k := range sortedKeys(values) {
			te = pbBytes(te, 4, pfAnnotation(k, values[k]))
		}
		for _, v := range []struct {
			name  string
			value int64
		}{{"gonka.height", e.Height}, {"gonka.round", e.Round}} {
			annotation := pbString(nil, 10, v.name)
			annotation = pbUint(annotation, 4, uint64(v.value))
			te = pbBytes(te, 4, annotation)
		}
		packet(uint64(ts), 11, te)
	}
	for _, m := range a.Measurements {
		if m.TraceNS == "" || m.Value == nil || m.Temporality != "historical" {
			continue
		}
		ts, err := strconv.ParseUint(m.TraceNS, 10, 64)
		if err != nil {
			continue
		}
		id := fmt.Sprintf("gonka/counter/%d/%d/%s/%s/%s/%s", m.Height, m.Round, m.Type, m.Target, m.Observer, m.Basis)
		name := fmt.Sprintf("Evidence points H%d R%d %s %s", m.Height, m.Round, m.Type, m.Basis)
		if m.Metric == "membership.active_power" {
			id = "gonka/power/" + m.Target
			targetLabel := m.Target
			if labels[m.Target] != "" {
				targetLabel = labels[m.Target]
			}
			name = "Voting power / " + targetLabel + " (height samples)"
			descriptor(id, name, false)
			values := map[string]string{"gonka.measurement_id": m.ID, "gonka.height": fmt.Sprint(m.Height), "gonka.power": fmt.Sprint(*m.Value), "gonka.time_basis": m.Basis, "gonka.coverage": m.Coverage}
			if len(m.SourceRefs) > 0 {
				values["gonka.source_ref"] = m.SourceRefs[0]
			}
			emit(ts, id, fmt.Sprintf("H%d power %d", m.Height, *m.Value), 3, values, nil)
			continue
		}
		descriptor(id, name, true)
		emit(ts, id, "", 4, map[string]string{"gonka.measurement_id": m.ID, "gonka.coverage": "discrete samples; do not interpolate"}, m.Value)
	}
	for _, interval := range a.Intervals {
		start, e1 := strconv.ParseUint(interval.StartNS, 10, 64)
		end, e2 := strconv.ParseUint(interval.EndNS, 10, 64)
		if e1 != nil || e2 != nil || end <= start {
			continue
		}
		id := "gonka/interval/" + interval.ActorID
		label := labels[interval.ActorID]
		if label == "" {
			label = interval.ActorID
		}
		descriptor(id, label+" · intervals", false)
		emit(start, id, interval.Phase, 1, map[string]string{"gonka.interval_id": interval.ID, "gonka.basis": interval.Basis, "gonka.from_event": interval.FromEvent, "gonka.to_event": interval.ToEvent}, nil)
		emit(end, id, "", 2, nil, nil)
	}
	// A single trusted sequence is timestamp ordered, including counter samples.
	sort.SliceStable(packets, func(i, j int) bool { return packets[i].ts < packets[j].ts })
	for _, p := range packets {
		out = pbBytes(out, 1, p.bytes)
	}
	return out
}
