package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

// ResolvePolicy makes the automatic network convention explicit and overridable.
func ResolvePolicy(requested, chain string) (string, error) {
	if requested == "" || requested == "auto" {
		name := strings.ToLower(chain)
		switch {
		case strings.Contains(name, "testnet"):
			return "testnet", nil
		case strings.Contains(name, "devnet"):
			return "devnet", nil
		default:
			return "strict", nil
		}
	}
	switch requested {
	case "strict", "testnet", "devnet":
		return requested, nil
	default:
		return "", fmt.Errorf("policy must be auto, strict, testnet or devnet")
	}
}

// refreshTestnet accepts an operator-authorized reset, not a new chain ID.
// Every retained seed must agree; full online validation still precedes writes.
func (t *Transport) refreshTestnet(ctx context.Context, doc Document) (Document, error) {
	doc.Seeds = append([]Seed(nil), doc.Seeds...)
	agreed := ""
	hosts, ids := map[string]bool{}, map[string]bool{}
	for i, seed := range doc.Seeds {
		rpc := strings.TrimRight(seed.RPC, "/")
		var status publicStatus
		if err := t.query(ctx, rpc+"/status", &status); err != nil {
			return doc, err
		}
		seed.NodeID = status.Result.NodeInfo.ID
		if err := t.status(ctx, seed, doc.ChainID); err != nil {
			return doc, err
		}
		raw, err := t.Get(ctx, rpc+"/genesis", GenesisLimit)
		if err != nil {
			return doc, err
		}
		genesis, err := GenesisBytes(raw)
		if err != nil {
			return doc, err
		}
		var identity struct {
			ChainID string `json:"chain_id"`
		}
		if err := DecodeJSON(genesis, &identity); err != nil || identity.ChainID != doc.ChainID {
			return doc, fmt.Errorf("testnet Genesis does not belong to requested chain ID")
		}
		sum := sha256.Sum256(genesis)
		digest := hex.EncodeToString(sum[:])
		if agreed != "" && agreed != digest {
			return doc, fmt.Errorf("testnet sources disagree on Genesis")
		}
		agreed = digest
		parsed, err := endpoint(rpc, "http", "https")
		if err != nil {
			return doc, err
		}
		hosts[parsed.Host], ids[seed.NodeID] = true, true
		doc.Seeds[i] = seed
	}
	if len(hosts) < 2 || len(ids) < 2 {
		return doc, fmt.Errorf("testnet reset requires two distinct RPC endpoints and node identities")
	}
	doc.Genesis.SHA256 = agreed
	raw, err := json.Marshal(doc)
	if err != nil {
		return doc, err
	}
	if _, err := Parse(raw, nil); err != nil {
		return doc, err
	}
	return doc, nil
}
