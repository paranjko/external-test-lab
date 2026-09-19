package main

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Decode only checksum-valid Gonka consensus addresses, never account/operator IDs.
func consensusAddress(s string) string {
	if validIdentity(s) {
		return strings.ToUpper(s)
	}
	const alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
	if !strings.HasPrefix(s, "gonkavalcons1") || s != strings.ToLower(s) {
		return ""
	}
	i := strings.LastIndexByte(s, '1')
	hrp, payload := s[:i], s[i+1:]
	if len(payload) < 6 {
		return ""
	}
	chk := uint32(1)
	step := func(v uint32) {
		top := chk >> 25
		chk = (chk&0x1ffffff)<<5 ^ v
		for i, g := range []uint32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3} {
			if top>>i&1 != 0 {
				chk ^= g
			}
		}
	}
	for _, c := range hrp {
		step(uint32(c) >> 5)
	}
	step(0)
	for _, c := range hrp {
		step(uint32(c) & 31)
	}
	values := []byte{}
	for _, c := range payload {
		v := strings.IndexRune(alphabet, c)
		if v < 0 {
			return ""
		}
		step(uint32(v))
		values = append(values, byte(v))
	}
	if chk != 1 {
		return ""
	}
	var acc uint32
	bits := uint(0)
	out := []byte{}
	for _, v := range values[:len(values)-6] {
		acc = (acc<<5 | uint32(v)) & 0xffff
		bits += 5
		for bits >= 8 {
			bits -= 8
			out = append(out, byte(acc>>bits))
		}
	}
	if bits >= 5 || (acc<<(8-bits))&255 != 0 || len(out) != 20 {
		return ""
	}
	return strings.ToUpper(hex.EncodeToString(out))
}

func (c *ConsensusTimeline) readLivenessEvents(m map[string]any, h int64, r Receipt) {
	for _, field := range []string{"begin_block_events", "end_block_events", "finalize_block_events"} {
		for i, raw := range list(m[field]) {
			e := object(raw)
			kind := str(e["type"])
			if kind != "slash" && kind != "liveness" {
				continue
			}
			attrs := map[string]string{}
			for _, raw := range list(e["attributes"]) {
				kv := object(raw)
				attrs[str(kv["key"])] = str(kv["value"])
			}
			typeName := "validator.liveness"
			if kind == "slash" {
				typeName = "validator.slashed"
				jailed := attrs["jailed"] == "true" || (consensusAddress(attrs["jailed"]) != "" && consensusAddress(attrs["jailed"]) == consensusAddress(attrs["address"]))
				if attrs["reason"] == "missing_signature" && jailed {
					typeName = "validator.jailed.liveness"
				}
			}
			attrs["source.kind"] = "ABCI block_results"
			c.add(ConsensusObservation{Height: h, Round: -1, Phase: "APPLICATION", Kind: typeName,
				Observer: r.Node, Validator: consensusAddress(attrs["address"]), Source: fmt.Sprintf("%s#/result/%s/%d", r.Path, field, i),
				TimeKind: "block header anchor; execution time unobserved", CollectedAt: r.Collected, Inferred: true,
				Message: fmt.Sprintf("ABCI %s: %v", kind, attrs), Attributes: attrs})
		}
	}
}
