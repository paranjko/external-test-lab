package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

func str(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func object(v any) map[string]any  { m, _ := v.(map[string]any); return m }
func list(v any) []any             { a, _ := v.([]any); return a }
func number(v any) int64           { n, _ := strconv.ParseInt(str(v), 10, 64); return n }
func timestamp(s string) time.Time { t, _ := time.Parse(time.RFC3339Nano, s); return t }

var secretRE = regexp.MustCompile(`(?i)("?(?:api[_-]?key|private[_-]?key|priv_key|password|mnemonic|seed_phrase|authorization|access_token|refresh_token|token|secret)"?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)`)
var bearerRE = regexp.MustCompile(`(?i)\b(?:Bearer\s+[^\s"']+|ctxio_[a-zA-Z0-9_-]+)`)
var pemRE = regexp.MustCompile(`(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----`)

func redact(s string) string {
	s = pemRE.ReplaceAllString(s, "[REDACTED PRIVATE KEY]")
	s = bearerRE.ReplaceAllString(s, "[REDACTED]")
	s = secretRE.ReplaceAllString(s, "${1}\"[REDACTED]\"")
	return s
}
func normalizeRPC(method string, b []byte, node string, h int64, ref string, at time.Time) []Event {
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return nil
	}
	base := Event{Node: node, Component: "cometbft", Height: h, Source: ref, Attr: map[string]string{}}
	switch method {
	case "commit":
		commit := object(object(m["signed_header"])["commit"])
		out := []Event{}
		round := number(commit["round"])
		for i, s := range list(commit["signatures"]) {
			v := object(s)
			flag := number(v["block_id_flag"])
			if flag != 2 && flag != 3 {
				continue
			}
			ev := base
			ev.Type = "consensus.precommit"
			ev.Height = number(commit["height"])
			ev.Round = &round
			ev.OriginalTimestamp = str(v["timestamp"])
			ev.Time = timestamp(ev.OriginalTimestamp)
			ev.Source = fmt.Sprintf("%s#/result/signed_header/commit/signatures/%d", ref, i)
			ev.Attr = map[string]string{"validator.address": str(v["validator_address"]), "block.hash": str(object(commit["block_id"])["hash"]), "block_id_flag": str(v["block_id_flag"]), "votes.basis": "retained commit signature; not independently cryptographically verified"}
			ev.Message = "RPC commit signature"
			out = append(out, ev)
		}
		return out
	case "block":
		header := object(object(m["block"])["header"])
		base.Time = timestamp(str(header["time"]))
		base.OriginalTimestamp = str(header["time"])
		base.Height = number(header["height"])
		base.Type = "block.commit"
		base.Attr["block.hash"] = str(object(m["block_id"])["hash"])
		base.Attr["chain.id"] = str(header["chain_id"])
		base.Message = "RPC committed block header"
		return []Event{base}
	case "block_results":
		out := []Event{}
		for i, tx := range list(m["txs_results"]) {
			r := object(tx)
			for j, item := range list(r["events"]) {
				record := object(item)
				attributes := map[string]string{}
				isJoin := false
				for _, item := range list(record["attributes"]) {
					kv := object(item)
					k, v := str(kv["key"]), str(kv["value"])
					attributes[k] = v
					if strings.Contains(v, "MsgSubmitNewParticipant") || strings.Contains(v, "MsgSubmitNewUnfundedParticipant") {
						isJoin = true
					}
				}
				if isJoin {
					ev := base
					ev.Type = "join.register"
					if number(r["code"]) != 0 {
						ev.Type = "join.register.failed"
					}
					ev.Source = fmt.Sprintf("%s#/result/txs_results/%d/events/%d", ref, i, j)
					ev.Attr = attributes
					ev.Attr["tx.index"] = strconv.Itoa(i)
					ev.Attr["tx.code"] = str(r["code"])
					ev.Message = "ABCI transaction message action; result code retained"
					out = append(out, ev)
				}
			}
		}
		for i, v := range list(m["validator_updates"]) {
			ev := base
			ev.Type = "validators.update"
			ev.Source = fmt.Sprintf("%s#/result/validator_updates/%d", ref, i)
			ev.Attr = map[string]string{"update.effective_height": strconv.FormatInt(h+2, 10), "voting_power.new": str(object(v)["power"])}
			if ev.Attr["voting_power.new"] == "" {
				ev.Attr["voting_power.new"] = "0"
			}
			key, _ := json.Marshal(object(v)["pub_key"])
			ev.Attr["validator.public_key"] = string(key)
			ev.Message = "ABCI validator update; H+2 activation inferred from CometBFT contract"
			out = append(out, ev)
		}
		return out
	case "status", "abci_info", "consensus_state", "dump_consensus_state":
		base.Type = "rpc." + method
		base.Current = true
		base.Time = at
		base.OriginalTimestamp = at.Format(time.RFC3339Nano)
		base.Message = "Current diagnostic snapshot, not historical round archive"
		base.Attr["observation.collected_at"] = at.Format(time.RFC3339Nano)
		if method == "status" {
			base.Height = number(object(m["sync_info"])["latest_block_height"])
		}
		out := []Event{base}
		rs := object(m["round_state"])
		heightRound := strings.Split(str(rs["height/round/step"]), "/")
		height := number(rs["height"])
		if len(heightRound) > 0 && heightRound[0] != "" {
			height = number(heightRound[0])
		}
		if method == "consensus_state" {
			for i, v := range list(rs["height_vote_set"]) {
				r := object(v)
				round := number(r["round"])
				for _, kind := range []string{"prevote", "precommit"} {
					ev := base
					ev.Type = "consensus." + kind
					ev.Height = height
					ev.Round = &round
					ev.Source = fmt.Sprintf("%s#/result/round_state/height_vote_set/%d", ref, i)
					ev.Attr = map[string]string{"observation.collected_at": at.Format(time.RFC3339Nano), "votes.bit_array": str(r[kind+"s_bit_array"]), "votes.basis": "RPC round snapshot; not live signer availability"}
					ev.Message = str(r[kind+"s"])
					out = append(out, ev)
				}
			}
		}
		return out
	}
	return nil
}

var ansiRE = regexp.MustCompile(`\x1b\[[0-9;]*m`)
var timeRE = regexp.MustCompile(`\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)`)
var heightRE = regexp.MustCompile(`(?i)\bheight["']?\s*[:=]\s*["']?(\d+)`)
var roundRE = regexp.MustCompile(`(?i)\bround["']?\s*[:=]\s*["']?(\d+)`)
var hrsRE = regexp.MustCompile(`\bh/r/s\s+(\d+)/(\d+)/(\d+)`)
var fieldsRE = regexp.MustCompile(`(?i)\b(step|tx_hash|txhash|block_hash|participant|consensus_key|validator_address|run_id|operation_id)["']?\s*[:=]\s*["']?([a-zA-Z0-9_:/+.=-]+)`)

func normalizeLog(raw, node, component, ref string, from, to int64, start, end time.Time, hasWindow bool) []Event {
	out := []Event{}
	scanner := bufio.NewScanner(strings.NewReader(raw))
	scanner.Buffer(make([]byte, 4096), maxSourceBytes)
	line := 0
	for scanner.Scan() {
		line++
		msg := redact(ansiRE.ReplaceAllString(scanner.Text(), ""))
		if strings.TrimSpace(msg) == "" {
			continue
		}
		ev := Event{Node: node, Component: component, Type: "log", Source: fmt.Sprintf("%s#L%d", ref, line), Message: msg, Attr: map[string]string{"correlation.basis": "explicit fields, otherwise time proximity; no causal claim"}}
		if t := timeRE.FindString(msg); t != "" {
			ev.OriginalTimestamp = t
			ev.Time = timestamp(strings.Replace(t, " ", "T", 1))
		}
		if m := heightRE.FindStringSubmatch(msg); len(m) > 1 {
			ev.Height = number(m[1])
		}
		if m := roundRE.FindStringSubmatch(msg); len(m) > 1 {
			r := number(m[1])
			ev.Round = &r
		}
		if m := hrsRE.FindStringSubmatch(msg); len(m) > 1 {
			ev.Height = number(m[1])
			r := number(m[2])
			ev.Round = &r
			ev.Attr["step"] = m[3]
		}
		if strings.Contains(strings.ToLower(msg), "cosmovisor") {
			ev.Component = "cosmovisor"
		}
		if times := timeRE.FindAllString(msg, -1); len(times) > 1 {
			ev.Attr["component.original_timestamp"] = times[1]
			ev.Attr["time.basis"] = "Docker capture timestamp; component timestamp retained separately"
		}
		for _, f := range fieldsRE.FindAllStringSubmatch(msg, -1) {
			ev.Attr[strings.ToLower(f[1])] = f[2]
		}
		if hasWindow && !ev.Time.IsZero() && (ev.Time.Before(start) || ev.Time.After(end)) {
			continue
		}
		if ev.Time.IsZero() && ev.Height > 0 && (ev.Height < from || ev.Height > to+1) {
			continue
		}
		l := strings.ToLower(msg)
		switch {
		case strings.Contains(l, "register") && (component == "gdc" || strings.Contains(l, "participant")):
			ev.Type = "join.register"
		case strings.Contains(l, "join") && (strings.Contains(l, "start") || strings.Contains(l, "phase")):
			ev.Type = "join.start"
		case (component == "tmkms" || strings.Contains(l, "signer")) && (strings.Contains(l, "error") || strings.Contains(l, "failed") || strings.Contains(l, "panic")):
			ev.Type = "signer.error"
		case (component == "tmkms" || strings.Contains(l, "signer")) && strings.Contains(l, "restart"):
			ev.Type = "signer.restart"
		case (component == "tmkms" || strings.Contains(l, "signer")) && (strings.Contains(l, "starting") || strings.Contains(l, "listening")):
			ev.Type = "signer.start"
		case component == "tmkms" && strings.Contains(l, "connected to validator"):
			ev.Type = "signer.connected"
		case strings.Contains(l, "timeout") || strings.Contains(l, "timed out"):
			ev.Type = "consensus.timeout"
		case strings.Contains(l, "precommit"):
			ev.Type = "consensus.precommit"
		case strings.Contains(l, "prevote"):
			ev.Type = "consensus.prevote"
		case strings.Contains(l, "committed state") || strings.Contains(l, "finalized block"):
			ev.Type = "block.commit"
		}
		out = append(out, ev)
	}
	return out
}
func inferTimes(d *Dataset) {
	headers := map[int64]time.Time{}
	for _, e := range d.Events {
		if e.Type == "block.commit" && !e.Time.IsZero() {
			headers[e.Height] = e.Time
		}
	}
	for i := range d.Events {
		e := &d.Events[i]
		if e.Time.IsZero() {
			e.Inferred = true
			if e.Attr == nil {
				e.Attr = map[string]string{}
			}
			t := headers[e.Height]
			if t.IsZero() && e.Height > 0 {
				best := int64(1 << 62)
				bestHeight := int64(1 << 62)
				for h, v := range headers {
					dist := h - e.Height
					if dist < 0 {
						dist = -dist
					}
					if dist < best || (dist == best && h < bestHeight) {
						t = v
						best = dist
						bestHeight = h
					}
				}
			}
			if t.IsZero() { // Prefer a real timestamp from the same source, never an unrelated file.
				base := strings.Split(e.Source, "#")[0]
				for j := i - 1; j >= 0; j-- {
					p := d.Events[j]
					if !p.Inferred && !p.Current && !p.Time.IsZero() && strings.Split(p.Source, "#")[0] == base {
						t = p.Time
						break
					}
				}
				if t.IsZero() {
					for j := i + 1; j < len(d.Events); j++ {
						p := d.Events[j]
						if !p.Inferred && !p.Current && !p.Time.IsZero() && strings.Split(p.Source, "#")[0] == base {
							t = p.Time
							break
						}
					}
				}
			}
			e.Attr["time.basis"] = "nearest retained height or timestamp in same source"
			if t.IsZero() {
				t = d.Collected
				e.Current = true
				if e.Attr == nil {
					e.Attr = map[string]string{}
				}
				e.Attr["time.basis"] = "no historical anchor; collection time placeholder"
			}
			e.Time = t
		}
	}
	sort.SliceStable(d.Events, func(i, j int) bool {
		a, b := d.Events[i], d.Events[j]
		if a.Time.Equal(b.Time) {
			return a.Source < b.Source
		}
		return a.Time.Before(b.Time)
	})
}
