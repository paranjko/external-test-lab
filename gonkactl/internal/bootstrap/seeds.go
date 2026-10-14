package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

const GenesisLimit = 64 * 1024 * 1024

type Check struct {
	Stage string `json:"stage"`
	URL   string `json:"url"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type Result struct {
	Policy           string   `json:"policy,omitempty"`
	Warnings         []string `json:"warnings,omitempty"`
	SoftwareDeclared *bool    `json:"software_declared,omitempty"`
	ChainID          string   `json:"chain_id"`
	BootstrapURL     string   `json:"bootstrap_url"`
	OK               bool     `json:"ok"`
	Checks           []Check  `json:"checks"`
}

func (r *Result) check(stage, address string, operation func() error) {
	item := Check{Stage: stage, URL: address, OK: true}
	if err := operation(); err != nil {
		item.OK = false
		item.Error = err.Error()
		if len(item.Error) > 400 {
			item.Error = item.Error[:400]
		}
	}
	r.Checks = append(r.Checks, item)
}

func (r *Result) complete() {
	r.OK = len(r.Checks) > 0
	for _, check := range r.Checks {
		r.OK = r.OK && check.OK
	}
}

// GenesisBytes preserves the RPC's raw result.genesis bytes, exactly as the
// native download-genesis contract requires; re-encoding would change its hash.
func GenesisBytes(raw []byte) ([]byte, error) {
	var envelope struct {
		Result struct {
			Genesis json.RawMessage `json:"genesis"`
		} `json:"result"`
	}
	if err := DecodeJSON(raw, &envelope); err != nil {
		return nil, err
	}
	genesis := envelope.Result.Genesis
	if len(genesis) == 0 || genesis[0] != '{' {
		return nil, fmt.Errorf("RPC response has no genesis object")
	}
	return genesis, nil
}

type publicStatus struct {
	Result struct {
		NodeInfo struct {
			ID         string
			Network    string
			ListenAddr string `json:"listen_addr"`
		} `json:"node_info"`
		ValidatorInfo struct {
			PubKey struct{ Value string } `json:"pub_key"`
		} `json:"validator_info"`
	} `json:"result"`
}

func (t *Transport) status(ctx context.Context, seed Seed, chain string) error {
	raw, err := t.Get(ctx, strings.TrimRight(seed.RPC, "/")+"/status", DocumentLimit)
	if err != nil {
		return err
	}
	var response publicStatus
	if err := DecodeJSON(raw, &response); err != nil {
		return err
	}
	s := response.Result
	if s.NodeInfo.ID != seed.NodeID || s.NodeInfo.Network != chain {
		return fmt.Errorf("RPC identity differs from bootstrap")
	}
	return nil
}

// CheckSeeds retains all independent failures; one broken endpoint must not
// suppress diagnostics for the remaining seeds. It is not a whole-bootstrap
// verdict: schema, publication and optional software checks are separate.
func (t *Transport) CheckSeeds(ctx context.Context, doc Document, result *Result) {
	for _, seed := range doc.Seeds {
		rpc := strings.TrimRight(seed.RPC, "/")
		result.check("rpc", rpc+"/status", func() error {
			return t.status(ctx, seed, doc.ChainID)
		})
		result.check("genesis", rpc+"/genesis", func() error {
			raw, err := t.Get(ctx, rpc+"/genesis", GenesisLimit)
			if err != nil {
				return err
			}
			genesis, err := GenesisBytes(raw)
			if err != nil {
				return err
			}
			digest := sha256.Sum256(genesis)
			if hex.EncodeToString(digest[:]) != doc.Genesis.SHA256 {
				return fmt.Errorf("genesis SHA-256 differs from bootstrap")
			}
			var identity struct {
				ChainID string `json:"chain_id"`
			}
			if err := json.Unmarshal(genesis, &identity); err != nil {
				return err
			}
			if identity.ChainID != doc.ChainID {
				return fmt.Errorf("genesis chain ID differs from bootstrap")
			}
			return nil
		})
		result.check("p2p", seed.P2P, func() error { return t.TCP(ctx, seed.P2P) })
	}
}
