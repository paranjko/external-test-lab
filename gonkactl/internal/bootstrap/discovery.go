package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"
)

const chainAPI = "/chain-api/productscience/inference/inference/"
const historyEpochs = 8

// Mainnet already has over 7,000 participants. Keep discovery bounded while
// allowing a complete inventory, rather than truncating trust inputs at 2,000.
const maxParticipantPages = 100

type participant struct {
	Address      string `json:"address"`
	API          string `json:"inference_url"`
	ValidatorKey string `json:"validator_key"`
	Status       string `json:"status"`
}

type discoveryView struct {
	Guardians    []string
	Participants []participant
	GuardianKeys map[string]string
}

func (t *Transport) query(ctx context.Context, address string, target any) error {
	raw, err := t.Get(ctx, address, GenesisLimit)
	if err != nil {
		return err
	}
	return DecodeJSON(raw, target)
}

func (t *Transport) matchingGenesis(ctx context.Context, rpc string, doc Document) error {
	raw, err := t.Get(ctx, strings.TrimRight(rpc, "/")+"/genesis", GenesisLimit)
	if err != nil {
		return err
	}
	genesis, err := GenesisBytes(raw)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(genesis)
	var identity struct {
		ChainID string `json:"chain_id"`
	}
	if err := DecodeJSON(genesis, &identity); err != nil {
		return err
	}
	if hex.EncodeToString(digest[:]) != doc.Genesis.SHA256 || identity.ChainID != doc.ChainID {
		return fmt.Errorf("discovery source Genesis differs from bootstrap")
	}
	return nil
}

func (t *Transport) discoveryView(ctx context.Context, origin string, guardians bool) (discoveryView, error) {
	return t.discoveryViewPolicy(ctx, origin, guardians, false)
}

func (t *Transport) discoveryViewPolicy(ctx context.Context, origin string, guardians, omitUnavailable bool) (discoveryView, error) {
	view := discoveryView{Guardians: []string{}, Participants: []participant{}, GuardianKeys: map[string]string{}}
	if guardians {
		var state struct {
			Params struct {
				Guardians *struct {
					Addresses *[]string `json:"guardian_addresses"`
				} `json:"genesis_guardian_params"`
			}
		}
		if err := t.query(ctx, origin+chainAPI+"params", &state); err != nil {
			return view, err
		}
		if state.Params.Guardians == nil || state.Params.Guardians.Addresses == nil {
			return view, fmt.Errorf("guardian state missing; absence is not an empty list")
		}
		view.Guardians = append(view.Guardians, (*state.Params.Guardians.Addresses)...)
		sort.Strings(view.Guardians)
		for index, address := range view.Guardians {
			if !chainName.MatchString(address) || (index > 0 && view.Guardians[index-1] == address) {
				return view, fmt.Errorf("invalid or duplicate guardian address")
			}
			var response struct {
				Validator struct {
					OperatorAddress string               `json:"operator_address"`
					ConsensusPubkey struct{ Key string } `json:"consensus_pubkey"`
				}
			}
			raw, err := t.Get(ctx, origin+"/chain-api/cosmos/staking/v1beta1/validators/"+url.PathEscape(address), GenesisLimit)
			if err != nil {
				if omitUnavailable && ctx.Err() == nil {
					continue
				}
				return view, err
			}
			if err := DecodeJSON(raw, &response); err != nil {
				return view, err
			}
			if response.Validator.OperatorAddress != address || response.Validator.ConsensusPubkey.Key == "" {
				return view, fmt.Errorf("guardian staking identity is incomplete")
			}
			view.GuardianKeys[address] = response.Validator.ConsensusPubkey.Key
		}
	}
	next := ""
	seenPages := map[string]bool{}
	seenAccounts := map[string]bool{}
	for page := 0; page < maxParticipantPages; page++ {
		query := url.Values{"pagination.limit": {"100"}}
		if next != "" {
			query.Set("pagination.key", next)
		}
		var response struct {
			Participants *[]participant `json:"participant"`
			Pagination   *struct {
				Next string `json:"next_key"`
			} `json:"pagination"`
		}
		if err := t.query(ctx, origin+chainAPI+"participant?"+query.Encode(), &response); err != nil {
			return view, err
		}
		if response.Participants == nil || response.Pagination == nil {
			return view, fmt.Errorf("incomplete participant inventory")
		}
		for _, entry := range *response.Participants {
			if entry.Address == "" || seenAccounts[entry.Address] {
				return view, fmt.Errorf("duplicate or missing participant address")
			}
			seenAccounts[entry.Address] = true
			view.Participants = append(view.Participants, entry)
		}
		next = response.Pagination.Next
		if next == "" {
			sort.Slice(view.Participants, func(i, j int) bool { return view.Participants[i].Address < view.Participants[j].Address })
			return view, nil
		}
		if seenPages[next] {
			return view, fmt.Errorf("participant pagination cycle")
		}
		seenPages[next] = true
	}
	return view, fmt.Errorf("participant pagination limit exceeded")
}

// discoverySources requires two independently identified seed transports to
// agree on chain identity and the complete selection inputs. An unavailable
// guardian response never turns into an empty-guardian fallback.
func (t *Transport) discoverySources(ctx context.Context, doc Document) ([]string, discoveryView, error) {
	return t.discoverySourcesPolicy(ctx, doc, false)
}

func (t *Transport) discoverySourcesPolicy(ctx context.Context, doc Document, omitUnavailable bool) ([]string, discoveryView, error) {
	origins := []string{}
	seenHosts := map[string]bool{}
	seenIDs := map[string]bool{}
	var selected discoveryView
	for _, seed := range doc.Seeds {
		parsed, err := endpoint(seed.RPC, "https", "http")
		if err != nil {
			continue
		}
		if seenHosts[parsed.Hostname()] || seenIDs[seed.NodeID] {
			continue
		}
		if _, err := t.status(ctx, seed, doc.ChainID); err != nil {
			continue
		}
		if err := t.matchingGenesis(ctx, seed.RPC, doc); err != nil {
			continue
		}
		origin := parsed.Scheme + "://" + parsed.Host
		view, err := t.discoveryViewPolicy(ctx, origin, omitUnavailable || doc.ChainID == "gonka-devnet-community", omitUnavailable)
		if err != nil {
			continue
		}
		if len(origins) > 0 && !reflect.DeepEqual(view, selected) {
			return nil, selected, fmt.Errorf("independent discovery sources disagree")
		}
		selected = view
		seenHosts[parsed.Hostname()], seenIDs[seed.NodeID] = true, true
		origins = append(origins, origin)
		if len(origins) == 2 {
			return origins, selected, nil
		}
	}
	return nil, selected, fmt.Errorf("fewer than two independent sources attest complete discovery inputs")
}

type weightedParticipant struct {
	Address string `json:"member_address"`
	Weight  string `json:"weight"`
}

func rankHistory(participants []participant, epochs [][]weightedParticipant, retained map[string]bool) ([]participant, error) {
	if len(epochs) != historyEpochs {
		return nil, fmt.Errorf("eight completed epochs are required for stability ranking")
	}
	scores := map[string]int{}
	for _, epoch := range epochs {
		seen := map[string]bool{}
		for _, entry := range epoch {
			weight, err := strconv.ParseInt(entry.Weight, 10, 64)
			if err != nil || entry.Address == "" || seen[entry.Address] {
				return nil, fmt.Errorf("invalid historical participant weights")
			}
			seen[entry.Address] = true
			if weight > 0 {
				scores[entry.Address]++
			}
		}
	}
	candidates := []participant{}
	for _, entry := range participants {
		if entry.Status == "ACTIVE" && scores[entry.Address] >= 6 {
			candidates = append(candidates, entry)
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		a, b := candidates[i], candidates[j]
		if scores[a.Address] != scores[b.Address] {
			return scores[a.Address] > scores[b.Address]
		}
		if retained[a.API] != retained[b.API] {
			return retained[a.API]
		}
		return a.Address < b.Address
	})
	return candidates, nil
}

func (t *Transport) historicalCandidates(ctx context.Context, origins []string, view discoveryView, doc Document) ([]participant, error) {
	current := int64(0)
	for _, origin := range origins {
		var response struct {
			LatestEpoch struct{ Index string } `json:"latest_epoch"`
		}
		if err := t.query(ctx, origin+chainAPI+"epoch_info", &response); err != nil {
			return nil, err
		}
		index, err := strconv.ParseInt(response.LatestEpoch.Index, 10, 64)
		if err != nil || index <= historyEpochs {
			return nil, fmt.Errorf("insufficient completed epoch history")
		}
		if current == 0 || index < current {
			current = index
		}
	}
	epochs := [][]weightedParticipant{}
	for offset := int64(1); offset <= historyEpochs; offset++ {
		var agreed []weightedParticipant
		for source, origin := range origins {
			var response struct {
				Group struct {
					Index   string                 `json:"epoch_index"`
					Weights *[]weightedParticipant `json:"validation_weights"`
				} `json:"epoch_group_data"`
			}
			index := strconv.FormatInt(current-offset, 10)
			if err := t.query(ctx, origin+chainAPI+"epoch_group_data/"+index, &response); err != nil {
				return nil, err
			}
			if response.Group.Index != index || response.Group.Weights == nil {
				return nil, fmt.Errorf("historical epoch response is incomplete")
			}
			weights := *response.Group.Weights
			sort.Slice(weights, func(i, j int) bool { return weights[i].Address < weights[j].Address })
			if source > 0 && !reflect.DeepEqual(agreed, weights) {
				return nil, fmt.Errorf("independent epoch histories disagree")
			}
			agreed = weights
		}
		epochs = append(epochs, agreed)
	}
	retained := map[string]bool{}
	for _, seed := range doc.Seeds {
		retained[seed.API] = true
	}
	return rankHistory(view.Participants, epochs, retained)
}

func (t *Transport) candidateSeed(ctx context.Context, p participant, chain string) (Seed, error) {
	api, err := endpoint(p.API, "http", "https")
	if err != nil || (api.Path != "" && api.Path != "/") {
		return Seed{}, fmt.Errorf("participant does not expose a supported public API origin")
	}
	seed := Seed{API: strings.TrimRight(p.API, "/"), RPC: strings.TrimRight(p.API, "/") + "/chain-rpc"}
	var status publicStatus
	if err := t.query(ctx, seed.RPC+"/status", &status); err != nil {
		return seed, err
	}
	// A participant may serve its public API through a non-validator full node.
	// Chain identity is checked here; Genesis and online checks still precede writes.
	if status.Result.NodeInfo.Network != chain {
		return seed, fmt.Errorf("participant RPC reports a different chain: %s", seed.RPC)
	}
	seed.NodeID = status.Result.NodeInfo.ID
	peer, err := endpoint(status.Result.NodeInfo.ListenAddr, "tcp")
	if err != nil || peer.Port() == "" || (peer.Path != "" && peer.Path != "/") {
		return seed, fmt.Errorf("participant has no advertised P2P endpoint")
	}
	if ip := net.ParseIP(peer.Hostname()); ip != nil && ip.IsUnspecified() {
		return seed, fmt.Errorf("participant advertises an unspecified P2P bind address")
	}
	seed.P2P = peer.String()
	return seed, nil
}

// DiscoverSeeds selects guardians when declared. Otherwise it ranks completed
// on-chain participation, not account age or a one-off HTTP success. Winners
// still require the complete online validation before any filesystem write.
func (t *Transport) DiscoverSeeds(ctx context.Context, doc Document) ([]Seed, error) {
	return t.discoverSeeds(ctx, doc, false, 0, &Result{})
}

func (t *Transport) discoverSeeds(ctx context.Context, doc Document, omitUnavailable bool, interval time.Duration, result *Result) ([]Seed, error) {
	origins, view, err := t.discoverySourcesPolicy(ctx, doc, omitUnavailable)
	if err != nil {
		return nil, err
	}
	candidates := []participant{}
	if len(view.Guardians) > 0 {
		for _, guardian := range view.Guardians {
			if omitUnavailable && view.GuardianKeys[guardian] == "" {
				result.Warnings = append(result.Warnings, "excluded guardian "+guardian+": staking identity unavailable on agreed sources")
				continue
			}
			matches := []participant{}
			for _, p := range view.Participants {
				if p.ValidatorKey == view.GuardianKeys[guardian] {
					matches = append(matches, p)
				}
			}
			if len(matches) != 1 {
				if omitUnavailable && len(matches) == 0 {
					result.Warnings = append(result.Warnings, "excluded guardian "+guardian+": registered participant unavailable")
					continue
				}
				return nil, fmt.Errorf("guardian has no unique registered participant identity")
			}
			candidates = append(candidates, matches[0])
		}
	} else {
		candidates, err = t.historicalCandidates(ctx, origins, view, doc)
		if err != nil {
			return nil, err
		}
		if len(candidates) < 2 {
			return nil, fmt.Errorf("fewer than two participants qualified in at least six of eight completed epochs")
		}
		candidates = candidates[:2]
	}
	if len(candidates) < 2 && !omitUnavailable {
		return nil, fmt.Errorf("guardian selection contains fewer than two participants")
	}
	seeds := []Seed{}
	for _, p := range candidates {
		seed, err := t.candidateSeed(ctx, p, doc.ChainID)
		if err != nil {
			if omitUnavailable && len(view.Guardians) > 0 && ctx.Err() == nil {
				result.Warnings = append(result.Warnings, "excluded guardian participant "+p.Address+": "+err.Error())
				continue
			}
			return nil, err
		}
		if omitUnavailable && len(view.Guardians) > 0 {
			probe := doc
			probe.Seeds = []Seed{seed}
			health := Result{}
			t.CheckSeeds(ctx, probe, interval, &health)
			health.complete()
			if !health.OK {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				for _, check := range health.Checks {
					if !check.OK {
						result.Warnings = append(result.Warnings, "excluded guardian participant "+p.Address+": "+check.Stage+": "+check.Error)
					}
				}
				continue
			}
		}
		seeds = append(seeds, seed)
	}
	if omitUnavailable && len(view.Guardians) > 0 && len(seeds) < 2 {
		ranked, err := t.historicalCandidates(ctx, origins, view, doc)
		if err != nil {
			return nil, err
		}
		guardianKeys := map[string]bool{}
		for _, key := range view.GuardianKeys {
			guardianKeys[key] = true
		}
		for _, p := range ranked {
			if guardianKeys[p.ValidatorKey] {
				continue
			}
			// Cosmos account/operator addresses share the Bech32 payload. An
			// unavailable staking lookup must not re-admit that guardian as a
			// historical non-guardian. This comparison only excludes candidates;
			// it is not an identity or checksum attestation.
			guardianAccount := false
			for _, guardian := range view.Guardians {
				if strings.HasPrefix(guardian, "gonkavaloper1") && strings.HasPrefix(p.Address, "gonka1") {
					operator := strings.TrimPrefix(guardian, "gonkavaloper1")
					account := strings.TrimPrefix(p.Address, "gonka1")
					if len(operator) > 6 && len(operator) == len(account) && operator[:len(operator)-6] == account[:len(account)-6] {
						guardianAccount = true
					}
				}
			}
			if guardianAccount {
				continue
			}
			seed, err := t.candidateSeed(ctx, p, doc.ChainID)
			if err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				result.Warnings = append(result.Warnings, "skipped historical participant "+p.Address+": "+err.Error())
				continue
			}
			duplicate := false
			for _, retained := range seeds {
				if seed.NodeID == retained.NodeID || seed.RPC == retained.RPC || seed.P2P == retained.P2P {
					duplicate = true
				}
			}
			if duplicate {
				continue
			}
			probe := doc
			probe.Seeds = []Seed{seed}
			health := Result{}
			t.CheckSeeds(ctx, probe, interval, &health)
			health.complete()
			if !health.OK {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				result.Warnings = append(result.Warnings, "skipped historical participant "+p.Address+": online validation failed")
				continue
			}
			seeds = append(seeds, seed)
			result.Warnings = append(result.Warnings, "added historical participant "+p.Address+" to maintain two healthy seeds")
			if len(seeds) == 2 {
				break
			}
		}
	}
	if len(seeds) < 2 {
		return nil, fmt.Errorf("fewer than two healthy seeds remain under update policy")
	}
	// Preserve retained endpoint order; new identities are ordered by RPC. This
	// avoids changing first-choice ENV endpoints merely due to API enumeration.
	order := map[string]int{}
	for index, seed := range doc.Seeds {
		order[seed.RPC] = index + 1
	}
	sort.Slice(seeds, func(i, j int) bool {
		a, b := order[seeds[i].RPC], order[seeds[j].RPC]
		if a != 0 && b != 0 {
			return a < b
		}
		if a != 0 || b != 0 {
			return a != 0
		}
		return seeds[i].RPC < seeds[j].RPC
	})
	candidate := doc
	candidate.Seeds = seeds
	raw, err := json.Marshal(candidate)
	if err != nil {
		return nil, err
	}
	if _, err := Parse(raw, nil); err != nil {
		return nil, err
	}
	return seeds, nil
}
