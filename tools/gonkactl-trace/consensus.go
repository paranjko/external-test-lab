package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"
)

type ConsensusValidator struct {
	Address, PublicKey string
	Index              int
	Power              int64
}
type ConsensusSet struct {
	Height           int64
	Observer, Source string
	Validators       []ConsensusValidator
	Total            int64
	Complete         bool
}
type ConsensusObservation struct {
	Height, Round                                                       int64
	Phase, Kind, Observer, Validator, Target, Source, Message, TimeKind string
	Time, CollectedAt                                                   time.Time
	DisplayOnly, Inferred                                               bool
	Attributes                                                          map[string]string
}
type ConsensusVote struct {
	Height, Round           int64
	Type, Validator, Target string
	Observations            []ConsensusObservation
}
type ConsensusHeight struct {
	Height       int64
	HeaderTime   time.Time
	BlockID      string
	Sets         map[string]ConsensusSet
	Rounds       map[int64]bool
	Observations []ConsensusObservation
}
type ConsensusUpdate struct {
	Emitted, Effective         int64
	Address, PublicKey, Source string
	Power                      int64
}
type ConsensusTimeline struct {
	LogDetailRanges       []HeightRange
	IdentityLabels        []InventoryLabel
	Incident, Chain       string
	From, To              int64
	Start, End, Collected time.Time
	Heights               map[int64]*ConsensusHeight
	Votes                 []ConsensusVote
	Updates               []ConsensusUpdate
	Gaps                  []string
	ImportedChanges       []PFChange
}

func (c *ConsensusTimeline) height(h int64) *ConsensusHeight {
	v := c.Heights[h]
	if v == nil {
		v = &ConsensusHeight{Height: h, Sets: map[string]ConsensusSet{}, Rounds: map[int64]bool{}}
		c.Heights[h] = v
	}
	return v
}
func (c *ConsensusTimeline) add(o ConsensusObservation) {
	if o.Height <= 0 {
		return
	}
	if strings.Contains(o.Source, "#L") && !includesHeight(c.LogDetailRanges, o.Height) && o.Kind != "validator.jailed.liveness" && o.Kind != "identity.historical" {
		return
	}
	h := c.height(o.Height)
	h.Observations = append(h.Observations, o)
	if o.Round >= 0 && o.Phase != "HEADER" && o.Phase != "APPLICATION" && o.Phase != "VALIDATORS" {
		h.Rounds[o.Round] = true
	}
}
func (c *ConsensusTimeline) orderedHeights() []int64 {
	keys := []int64{}
	for h := range c.Heights {
		keys = append(keys, h)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	return keys
}
func quorum(t int64) int64 { return 2*(t/3) + 2*(t%3)/3 + 1 }
func blockTarget(v any) string {
	m := object(v)
	hash := strings.ToUpper(str(m["hash"]))
	if hash == "" {
		return "nil"
	}
	parts := object(m["parts"])
	if len(parts) == 0 {
		parts = object(m["part_set_header"])
	}
	if str(parts["hash"]) == "" {
		return hash
	}
	return fmt.Sprintf("%s:%s:%s", hash, str(parts["total"]), strings.ToUpper(str(parts["hash"])))
}
func keyAddress(key string) string {
	b, e := base64.StdEncoding.DecodeString(key)
	if e != nil || len(b) != 32 {
		return ""
	}
	h := sha256.Sum256(b)
	return strings.ToUpper(hex.EncodeToString(h[:20]))
}
func publicKey(v any) string {
	m := object(v)
	if s, ok := m["value"].(string); ok {
		return s
	}
	return str(object(object(m["Sum"])["value"])["ed25519"])
}
func setSignature(s ConsensusSet) string {
	vs := append([]ConsensusValidator(nil), s.Validators...)
	sort.Slice(vs, func(i, j int) bool { return vs[i].Address < vs[j].Address })
	b, _ := json.Marshal(vs)
	return string(b)
}
func (h *ConsensusHeight) set(observer string) (ConsensusSet, bool) {
	if observer != "" {
		s, ok := h.Sets[observer]
		return s, ok && s.Complete
	}
	var found ConsensusSet
	signature := ""
	nodes := make([]string, 0, len(h.Sets))
	for node := range h.Sets {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)
	for _, node := range nodes {
		s := h.Sets[node]
		if !s.Complete {
			continue
		}
		sig := setSignature(s)
		if signature != "" && sig != signature {
			return ConsensusSet{}, false
		}
		signature = sig
		found = s
	}
	return found, signature != ""
}
func (c *ConsensusTimeline) resolve(h, r int64, prefix string) string {
	prefix = strings.ToUpper(prefix)
	if prefix == "NIL" || prefix == "<NIL>" || prefix == "000000000000" {
		return "nil"
	}
	if prefix == "" {
		return "unknown"
	}
	matches := map[string]bool{}
	height := c.height(h)
	for _, o := range height.Observations {
		if o.Round == r && strings.Count(o.Target, ":") == 2 && len(strings.Split(o.Target, ":")[2]) == 64 && strings.HasPrefix(o.Target, prefix) {
			matches[o.Target] = true
		}
	}
	if len(matches) == 1 {
		for target := range matches {
			return target
		}
	}
	return "unknown:" + prefix
}
func buildConsensus(d Dataset) (ConsensusTimeline, error) {
	c := ConsensusTimeline{Incident: d.Config.Incident, Chain: d.Config.Chain, From: d.From, To: d.To, Start: d.Start, End: d.End.Add(time.Duration(d.Config.PaddingSeconds) * time.Second), Collected: d.Collected, Heights: map[int64]*ConsensusHeight{}}
	c.LogDetailRanges = d.Config.LogDetailRanges
	if len(c.LogDetailRanges) > 0 {
		c.Gaps = append(c.Gaps, fmt.Sprintf("Detailed log projection limited to height ranges %v; raw streams retained; jails and historical identity records retained outside those ranges", c.LogDetailRanges))
	}
	c.IdentityLabels = d.Config.IdentityLabels
	if len(d.Config.History) > 0 {
		c.Gaps = append(c.Gaps, "Explicit historical checkpoint selection: intermediate blocks, signatures and delivery events are not continuously covered; absent samples are not zero")
	}
	receipts := append([]Receipt(nil), d.Receipts...)
	sort.Slice(receipts, func(i, j int) bool { return receipts[i].Path < receipts[j].Path })
	type pages struct {
		values map[int64][]ConsensusValidator
		total  int64
		s      ConsensusSet
		valid  bool
	}
	sets := map[string]*pages{}
	for _, r := range receipts {
		if r.Error != "" {
			c.Gaps = append(c.Gaps, r.Node+" "+r.Source+": "+r.Error)
			continue
		}
		if !strings.HasPrefix(r.Source, "http") {
			continue
		}
		if r.Application != nil {
			continue
		}
		b, e := readReceipt(r)
		if e != nil {
			c.Gaps = append(c.Gaps, e.Error())
			continue
		}
		var envelope rpcResult
		if json.Unmarshal(b, &envelope) != nil {
			continue
		}
		var m map[string]any
		if json.Unmarshal(envelope.Result, &m) != nil {
			continue
		}
		u, e := url.Parse(r.Source)
		if e != nil {
			continue
		}
		method := path.Base(u.Path)
		h := number(u.Query().Get("height"))
		switch method {
		case "validators":
			k := fmt.Sprintf("%s/%d", r.Node, h)
			p := sets[k]
			if p == nil {
				p = &pages{values: map[int64][]ConsensusValidator{}, total: number(m["total"]), s: ConsensusSet{Height: h, Observer: r.Node}, valid: true}
				sets[k] = p
			}
			page := number(u.Query().Get("page"))
			if page < 1 || number(m["block_height"]) != h || number(m["total"]) != p.total || p.values[page] != nil {
				p.valid = false
			}
			p.s.Source += r.Path + " "
			for _, item := range list(m["validators"]) {
				v := object(item)
				power, err := strconv.ParseInt(str(v["voting_power"]), 10, 64)
				if err != nil || power < 0 || power > 1<<50 {
					p.valid = false
				}
				p.values[page] = append(p.values[page], ConsensusValidator{Address: strings.ToUpper(str(v["address"])), PublicKey: publicKey(v["pub_key"]), Power: power})
			}
		case "block":
			header := object(object(m["block"])["header"])
			if str(header["chain_id"]) != d.Config.Chain {
				c.Gaps = append(c.Gaps, "chain mismatch: "+r.Path)
				continue
			}
			ch := c.height(number(header["height"]))
			ch.HeaderTime = timestamp(str(header["time"]))
			ch.BlockID = blockTarget(m["block_id"])
			c.add(ConsensusObservation{Height: ch.Height, Round: -1, Phase: "HEADER", Kind: "header.timestamp", Time: ch.HeaderTime, TimeKind: "header", Observer: r.Node, Source: r.Path, Target: ch.BlockID})
			// last_commit is H-1, not the header height.
			c.readCommit(object(object(m["block"])["last_commit"]), r, r.Path+"#/result/block/last_commit")
		case "commit":
			c.readCommit(object(object(m["signed_header"])["commit"]), r, r.Path+"#/result/signed_header/commit")
		case "block_results":
			c.readLivenessEvents(m, h, r)
			for i, item := range list(m["validator_updates"]) {
				v := object(item)
				key := publicKey(v["pub_key"])
				c.Updates = append(c.Updates, ConsensusUpdate{Emitted: h, Effective: h + 2, Address: keyAddress(key), PublicKey: key, Power: number(v["power"]), Source: fmt.Sprintf("%s#/result/validator_updates/%d", r.Path, i)})
			}
		case "consensus_state", "dump_consensus_state":
			c.readSnapshot(m, method, r)
		case "status":
			info := object(m["validator_info"])
			c.add(ConsensusObservation{Height: d.To + 1, Round: -1, Phase: "IDENTITY", Kind: "current.identity", Observer: r.Node, Validator: str(info["address"]), Source: r.Path, Time: r.Collected, CollectedAt: r.Collected, DisplayOnly: true, Attributes: map[string]string{"public_key": publicKey(info["pub_key"]), "binding.basis": "current RPC identity only; not a historical host binding"}})
		}
	}
	for _, p := range sets {
		nums := []int64{}
		for page := range p.values {
			nums = append(nums, page)
		}
		sort.Slice(nums, func(i, j int) bool { return nums[i] < nums[j] })
		seen := map[string]bool{}
		for i, page := range nums {
			if page != int64(i+1) {
				p.valid = false
			}
			for _, v := range p.values[page] {
				v.Index = len(p.s.Validators)
				if v.Address == "" || seen[v.Address] {
					p.valid = false
				}
				seen[v.Address] = true
				p.s.Validators = append(p.s.Validators, v)
				p.s.Total += v.Power
			}
		}
		p.s.Complete = p.valid && int64(len(p.s.Validators)) == p.total && p.s.Total > 0
		c.height(p.s.Height).Sets[p.s.Observer] = p.s
	}
	for _, height := range c.Heights {
		for i := range height.Observations {
			o := &height.Observations[i]
			if o.TimeKind == "block header anchor; execution time unobserved" {
				o.Time = height.HeaderTime
			}
		}
	}
	c.readEvents(d.Events)
	c.correlate()
	c.Gaps = append(c.Gaps, "Historical WAL/received-vote stream not collected: delivery times, locks and all intermediate rounds may be unknown", "JOIN receipts linking historical node5 identities are incomplete; missing votes do not prove private-key deletion")
	return c, nil
}
func (c *ConsensusTimeline) readCommit(m map[string]any, r Receipt, source string) {
	h, round := number(m["height"]), number(m["round"])
	if h < c.From || h > c.To+1 {
		return
	}
	target := blockTarget(m["block_id"])
	signatures, _ := json.Marshal(m["signatures"])
	commitExcerpt, _ := json.Marshal(m)
	c.add(ConsensusObservation{Height: h, Round: round, Phase: "COMMIT", Kind: "commit.certificate", Target: target, Observer: r.Node, Source: source, CollectedAt: r.Collected, DisplayOnly: true, TimeKind: "certificate, decision time unknown", Message: string(commitExcerpt), Attributes: map[string]string{"signature_content": pfID(string(signatures))}})
	for i, item := range list(m["signatures"]) {
		v := object(item)
		flag := number(v["block_id_flag"])
		if (flag != 2 && flag != 3) || str(v["signature"]) == "" {
			continue
		}
		t := target
		if flag == 3 {
			t = "nil"
		}
		excerpt, _ := json.Marshal(v)
		c.add(ConsensusObservation{Height: h, Round: round, Phase: "PRECOMMIT", Kind: "vote.certificate", Validator: strings.ToUpper(str(v["validator_address"])), Target: t, Observer: r.Node, Time: timestamp(str(v["timestamp"])), TimeKind: "signature, not reception", CollectedAt: r.Collected, Source: fmt.Sprintf("%s/signatures/%d", source, i), Message: string(excerpt)})
	}
}
func (c *ConsensusTimeline) readSnapshot(m map[string]any, method string, r Receipt) {
	rs := object(m["round_state"])
	h, round, step := number(rs["height"]), number(rs["round"]), number(rs["step"])
	if hrs := strings.Split(str(rs["height/round/step"]), "/"); len(hrs) == 3 {
		h, round, step = number(hrs[0]), number(hrs[1]), number(hrs[2])
	}
	if h <= 0 {
		return
	}
	target := str(rs["proposal_block_hash"])
	if proposal := object(rs["proposal"]); len(proposal) > 0 {
		target = blockTarget(proposal["block_id"])
	}
	attrs := map[string]string{"round_step": strconv.FormatInt(step, 10), "locked_round": str(rs["locked_round"]), "valid_round": str(rs["valid_round"]), "locked_block_hash": str(rs["locked_block_hash"]), "valid_block_hash": str(rs["valid_block_hash"])}
	c.add(ConsensusObservation{Height: h, Round: round, Phase: "SNAPSHOT", Kind: "state.snapshot", Observer: r.Node, Target: target, Validator: str(object(m["proposer"])["address"]), Time: r.Collected, CollectedAt: r.Collected, Source: r.Path, DisplayOnly: true, Attributes: attrs})
	buckets := list(rs["height_vote_set"])
	if buckets == nil {
		buckets = list(rs["votes"])
	}
	for i, item := range buckets {
		bucket := object(item)
		br := number(bucket["round"])
		nonempty := false
		for _, kind := range []string{"prevotes", "precommits"} {
			for _, v := range list(bucket[kind]) {
				if strings.HasPrefix(str(v), "Vote{") {
					nonempty = true
				}
			}
		}
		if br != round && !nonempty {
			continue
		}
		for _, kind := range []string{"prevotes", "precommits"} {
			phase := "PREVOTE"
			if kind == "precommits" {
				phase = "PRECOMMIT"
			}
			c.add(ConsensusObservation{Height: h, Round: br, Phase: phase, Kind: "vote.snapshot.summary", Observer: r.Node, Time: r.Collected, CollectedAt: r.Collected, DisplayOnly: true, Source: fmt.Sprintf("%s#bucket/%d/%s", r.Path, i, kind), Attributes: map[string]string{"bit_array": str(bucket[kind+"_bit_array"]), "source.method": method}})
			for j, v := range list(bucket[kind]) {
				if parsed, ok := parseVoteText(str(v)); ok && parsed.Height == h && parsed.Round == br {
					parsed.Phase = phase
					parsed.Kind = "vote.snapshot"
					parsed.Observer = r.Node
					parsed.CollectedAt = r.Collected
					parsed.DisplayOnly = true
					parsed.Source = fmt.Sprintf("%s#bucket/%d/%s/%d", r.Path, i, kind, j)
					parsed.Message = str(v)
					c.add(parsed)
				}
			}
		}
	}
}
