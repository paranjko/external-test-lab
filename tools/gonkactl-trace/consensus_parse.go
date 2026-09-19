package main

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var voteTextRE = regexp.MustCompile(`Vote\{(\d+):([A-Fa-f0-9]+) (\d+)/(\d+)/[^ ]+ ([A-Fa-f0-9]+|<nil>) .* @ ([^}]+)\}`)
var proposalRE = regexp.MustCompile(`Proposal\{(\d+)/(\d+) \(([A-Fa-f0-9]+):(\d+):([A-Fa-f0-9]+), (-?\d+)\)`)
var signedRE = regexp.MustCompile(`signed (Proposal|PreVote|PreCommit):([A-Fa-f0-9]+|<nil>) at h/r/s (\d+)/(\d+)/(\d+)`)
var validatorObjectRE = regexp.MustCompile(`(?:^|\s)validator=("(?:\\.|[^"\\])*")`)
var monikerRE = regexp.MustCompile(`moniker:"([^"]+)"`)
var protoKeyRE = regexp.MustCompile(`consensus_pubkey:<type_url:"/cosmos.crypto.ed25519.PubKey" value:("(?:\\.|[^"\\])*")`)

func historicalIdentity(msg string) (string, string) {
	m := validatorObjectRE.FindStringSubmatch(msg)
	if len(m) == 0 {
		return "", ""
	}
	decoded, e := strconv.Unquote(m[1])
	if e != nil {
		return "", ""
	}
	name, key := monikerRE.FindStringSubmatch(decoded), protoKeyRE.FindStringSubmatch(decoded)
	if len(name) == 0 || len(key) == 0 || !strings.HasPrefix(name[1], "gdc-node") {
		return "", ""
	}
	raw, e := strconv.Unquote(key[1])
	if e != nil || len(raw) != 34 || raw[0] != 10 || raw[1] != 32 {
		return "", ""
	}
	return strings.TrimPrefix(name[1], "gdc-"), base64.StdEncoding.EncodeToString([]byte(raw[2:]))
}

func logField(msg, key string) string {
	re := regexp.MustCompile(`(?:^|\s)` + regexp.QuoteMeta(key) + `=("[^"]*"|[^\s]+)`)
	m := re.FindStringSubmatch(msg)
	if len(m) < 2 {
		return ""
	}
	return strings.Trim(m[1], `"`)
}
func parseVoteText(msg string) (ConsensusObservation, bool) {
	m := voteTextRE.FindStringSubmatch(msg)
	if len(m) == 0 {
		return ConsensusObservation{}, false
	}
	phase := "PREVOTE"
	if strings.Contains(msg, "Precommit") {
		phase = "PRECOMMIT"
	}
	return ConsensusObservation{Height: number(m[3]), Round: number(m[4]), Validator: strings.ToUpper(m[2]), Target: strings.ToUpper(m[5]), Phase: phase, Time: timestamp(m[6]), TimeKind: "signature, not reception", Attributes: map[string]string{"validator.index": m[1]}}, true
}
func (c *ConsensusTimeline) readEvents(events []Event) {
	epochs := map[string]int64{}
	processing := map[string]int64{}
	rounds := map[string]int64{}
	steps := map[string]int{}
	for _, e := range events {
		if e.Current || e.Inferred || e.Component == "cometbft" {
			continue
		}
		msg := ansiRE.ReplaceAllString(e.Message, "")
		module := logField(msg, "module")
		h := number(logField(msg, "height"))
		if v := logField(msg, "blockHeight"); v != "" {
			h = number(v)
		}
		r := int64(-1)
		if v := logField(msg, "round"); v != "" {
			r = number(v)
		}
		o := ConsensusObservation{Height: h, Round: r, Observer: e.Node, Time: e.Time, TimeKind: "log record", Source: e.Source, Message: msg, Attributes: map[string]string{"module": module}}
		for key, value := range e.Attr {
			if strings.HasPrefix(key, "process.") {
				o.Attributes[key] = value
			}
		}
		if module == "x/staking" {
			if host, key := historicalIdentity(msg); host != "" && processing[e.Node] > 0 {
				c.add(ConsensusObservation{Height: processing[e.Node], Round: -1, Phase: "IDENTITY", Kind: "identity.historical", Observer: e.Node, Validator: keyAddress(key), Time: e.Time, Source: e.Source, Message: msg, Inferred: true, Attributes: map[string]string{"host.label": host, "public_key": key, "binding.basis": "staking moniker during block execution; not proof of signing-key possession"}})
			}
		}
		if m := signedRE.FindStringSubmatch(msg); len(m) > 0 && e.Component == "tmkms" {
			o.Height, o.Round = number(m[3]), number(m[4])
			o.Target = strings.ToUpper(m[2])
			o.Kind = "signer.signed"
			o.Phase = map[string]string{"Proposal": "PROPOSE", "PreVote": "PREVOTE", "PreCommit": "PRECOMMIT"}[m[1]]
			o.Attributes["tmkms.step"] = m[5]
			o.Attributes["step.namespace"] = "TMKMS signing state: proposal=0, prevote=1, precommit=2; not RoundStep"
			o.Attributes["component.timestamp"] = e.Attr["component.original_timestamp"]
			o.TimeKind = "signer log, not network delivery"
		} else if module == "consensus" {
			switch {
			case strings.Contains(msg, "received proposal"):
				m := proposalRE.FindStringSubmatch(msg)
				if len(m) == 0 {
					continue
				}
				o.Height, o.Round = number(m[1]), number(m[2])
				o.Target = m[3] + ":" + m[4] + ":" + m[5]
				o.Validator = logField(msg, "proposer")
				o.Attributes["pol_round"] = m[6]
				o.Kind = "proposal.received"
				o.Phase = "PROPOSE"
				rounds[fmt.Sprintf("%s/%d", e.Node, o.Height)] = o.Round
			case strings.Contains(msg, "received complete proposal block"):
				o.Kind = "proposal.complete"
				o.Phase = "PROPOSE"
				o.Target = logField(msg, "hash")
				if v, ok := rounds[fmt.Sprintf("%s/%d", e.Node, h)]; ok {
					o.Round = v
				}
			case strings.Contains(msg, "finalizing commit"):
				processing[e.Node] = h
				o.Kind = "commit.finalizing"
				o.Phase = "COMMIT"
				o.Target = logField(msg, "hash")
			case strings.Contains(msg, "Timed out") || strings.Contains(msg, "received tock"):
				o.Kind = "timer.expired"
				o.Phase = "TIMERS"
				o.Attributes["timer.step"] = logField(msg, "step")
				o.Attributes["transition"] = "not established by timer record"
				if o.Attributes["timer.step"] == "RoundStepNewHeight" {
					o.Kind = "newheight.wait.elapsed"
					o.Phase = "NEWHEIGHT"
					o.Attributes["normal"] = "scheduled inter-height wait, not an error"
				}
			case strings.Contains(msg, "entering new round"):
				o.Kind = "state.newround"
				o.Phase = "NEWROUND"
			case strings.Contains(msg, "entering prevote wait"):
				o.Kind = "state.prevote_wait"
				o.Phase = "PREVOTEWAIT"
			case strings.Contains(msg, "entering precommit wait"):
				o.Kind = "state.precommit_wait"
				o.Phase = "PRECOMMITWAIT"
			case strings.Contains(msg, "entering prevote"):
				o.Kind = "state.prevote"
				o.Phase = "PREVOTE"
			case strings.Contains(msg, "entering precommit"):
				o.Kind = "state.precommit"
				o.Phase = "PRECOMMIT"
			case strings.Contains(strings.ToLower(msg), "unlock") || strings.Contains(strings.ToLower(msg), "relock") || strings.Contains(strings.ToLower(msg), "locking"):
				o.Kind = "lock.observed"
				o.Phase = "LOCK"
				o.Attributes["locked_round"] = logField(msg, "lockedRound")
				o.Attributes["valid_round"] = logField(msg, "validRound")
			case strings.Contains(msg, "added vote") || strings.Contains(msg, "received vote"):
				v, ok := parseVoteText(msg)
				if !ok {
					continue
				}
				v.Kind = "vote.received"
				v.Observer = o.Observer
				v.Source = o.Source
				v.Message = msg
				v.Attributes["signature.timestamp"] = v.Time.Format(time.RFC3339Nano)
				v.Time = e.Time
				v.TimeKind = "local vote reception log"
				o = v
			default:
				continue
			}
		} else if module == "x/slashing" && strings.Contains(msg, "slashing and jailing validator due to liveness fault") {
			o.Kind, o.Phase = "validator.jailed.liveness", "APPLICATION"
			o.Validator = consensusAddress(logField(msg, "validator"))
			for _, key := range []string{"validator", "jailed_until", "min_height", "threshold", "slashed"} {
				o.Attributes[key] = logField(msg, key)
			}
			o.Attributes["reason"] = "missing_signature"
		} else if strings.Contains(msg, "EpochGroupChanged") && module == "x/inference" {
			o.Kind = "epoch.changed"
			o.Phase = "APPLICATION"
			if h > 0 {
				epochs[e.Node] = h
			} else {
				o.Height = epochs[e.Node]
				o.Inferred = true
				o.Attributes["height.basis"] = "preceding EpochGroupChanged on same node"
			}
			if strings.Contains(msg, "computeResult=") {
				o.Kind = "epoch.compute"
			}
		} else if module == "state" && (strings.Contains(strings.ToLower(msg), "error") || strings.Contains(strings.ToLower(msg), "failed")) && h > 0 {
			o.Kind = "application.error"
			o.Phase = "EXECUTE"
		} else if module == "state" && (strings.Contains(msg, "executed block") || strings.Contains(msg, "finalized block") || strings.Contains(msg, "committed state")) {
			o.Kind = "application.executed"
			o.Phase = "EXECUTE"
		} else {
			continue
		}
		if o.Round < 0 {
			if v, ok := rounds[fmt.Sprintf("%s/%d", e.Node, o.Height)]; ok {
				o.Round = v
				o.Attributes["round.basis"] = "preceding proposal on same node and height"
			}
		}
		key := fmt.Sprintf("%s/%d/%d", o.Observer, o.Height, o.Round)
		rank := phaseRank(o.Phase)
		if o.Kind == "timer.expired" {
			timerRank := phaseRank(strings.ToUpper(strings.TrimPrefix(o.Attributes["timer.step"], "RoundStep")))
			if steps[key] > timerRank {
				o.Attributes["transition"] = "stale timer relative to already observed phase; no regression"
				o.Kind = "timer.stale"
			}
		}
		if rank > steps[key] {
			steps[key] = rank
		}
		for key, value := range e.Attr {
			if strings.HasPrefix(key, "process.") {
				o.Attributes[key] = value
			}
		}
		c.add(o)
	}
}
func phaseRank(s string) int {
	return map[string]int{"NEWHEIGHT": 1, "NEWROUND": 2, "PROPOSE": 3, "PREVOTE": 4, "PREVOTEWAIT": 5, "PRECOMMIT": 6, "PRECOMMITWAIT": 7, "COMMIT": 8, "EXECUTE": 9}[s]
}
func (c *ConsensusTimeline) correlate() {
	// Resolve complete targets and address prefixes only inside the same H/R.
	for _, h := range c.Heights {
		for i := range h.Observations {
			o := &h.Observations[i]
			if o.Target != "" {
				original := o.Target
				o.Target = c.resolve(o.Height, o.Round, o.Target)
				if original != o.Target {
					if o.Attributes == nil {
						o.Attributes = map[string]string{}
					}
					o.Attributes["target.original"] = original
					o.Attributes["target.basis"] = "unique retained BlockID matching prefix in same H/R; not cryptographic verification"
					o.Inferred = true
				}
			}
			if o.Validator != "" && len(o.Validator) != 40 {
				if s, ok := h.set(o.Observer); ok {
					matches := []string{}
					for _, v := range s.Validators {
						if strings.HasPrefix(v.Address, o.Validator) {
							matches = append(matches, v.Address)
						}
					}
					if len(matches) == 1 {
						o.Validator = matches[0]
					} else {
						o.Validator = "unknown:" + o.Validator
					}
				}
			}
			if index, exists := o.Attributes["validator.index"]; exists {
				if s, ok := h.set(o.Observer); ok {
					i, err := strconv.Atoi(index)
					if err != nil || i < 0 || i >= len(s.Validators) || s.Validators[i].Address != o.Validator {
						o.Validator = "unknown:index-mismatch:" + o.Validator
					}
				}
			}
		}
	}
	// Bind a signer only with same-round proposal evidence or unique matching signature timing.
	for _, h := range c.Heights {
		for i := range h.Observations {
			o := &h.Observations[i]
			if o.Kind != "signer.signed" {
				continue
			}
			candidates := map[string][]string{}
			for _, other := range h.Observations {
				if other.Round != o.Round || other.Target != o.Target || other.Validator == "" || strings.HasPrefix(other.Validator, "unknown:") {
					continue
				}
				match := o.Phase == "PROPOSE" && other.Kind == "proposal.received"
				if (other.Kind == "vote.certificate" || other.Kind == "vote.snapshot") && other.Phase == o.Phase {
					delta := o.Time.Sub(other.Time)
					if delta < 0 {
						delta = -delta
					}
					match = delta <= 20*time.Millisecond
				}
				if match {
					candidates[other.Validator] = append(candidates[other.Validator], other.Source)
				}
			}
			if len(candidates) == 1 {
				for addr, refs := range candidates {
					o.Validator = addr
					o.Inferred = true
					o.Attributes["identity.basis"] = "same H/R/target and unique proposal signer or signature timestamp within 20ms; inferred, not cryptographic verification"
					o.Attributes["identity.sources"] = strings.Join(refs, ",")
				}
			}
		}
	}
	merged := map[string]*ConsensusVote{}
	for _, h := range c.Heights {
		for _, o := range h.Observations {
			if o.Phase != "PREVOTE" && o.Phase != "PRECOMMIT" {
				continue
			}
			if o.Kind != "vote.certificate" && o.Kind != "vote.snapshot" && o.Kind != "vote.received" && o.Kind != "signer.signed" {
				continue
			}
			validator := o.Validator
			if validator == "" {
				validator = "unknown@" + o.Observer
			}
			key := fmt.Sprintf("%s/%d/%d/%s/%s/%s", c.Chain, o.Height, o.Round, o.Phase, validator, o.Target)
			v := merged[key]
			if v == nil {
				v = &ConsensusVote{Height: o.Height, Round: o.Round, Type: o.Phase, Validator: validator, Target: o.Target}
				merged[key] = v
			}
			v.Observations = append(v.Observations, o)
		}
	}
	keys := []string{}
	for k := range merged {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		c.Votes = append(c.Votes, *merged[k])
	}
	for _, h := range c.Heights {
		sort.SliceStable(h.Observations, func(i, j int) bool {
			a, b := h.Observations[i], h.Observations[j]
			if a.Time.Equal(b.Time) {
				return a.Source < b.Source
			}
			return a.Time.Before(b.Time)
		})
	}
}
