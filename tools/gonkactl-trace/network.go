package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const defaultBootstrapBaseURL = "https://gonka-dev.net"

var bootstrapBaseURL = defaultBootstrapBaseURL

type bootstrapDocument struct {
	Seeds []bootstrapSeed `json:"seeds"`
}

type bootstrapSeed struct {
	NodeID string `json:"node_id"`
	RPC    string `json:"rpc"`
}

func resolveNetworkAlias(value string) (string, error) {
	switch value {
	case "mainnet", "gonka-mainnet":
		return "gonka-mainnet", nil
	case "devnet", "gonka-devnet-community":
		return "gonka-devnet-community", nil
	case "testnet", "gonka-testnet":
		return "gonka-testnet", nil
	default:
		return "", fmt.Errorf("unknown chain ID or alias: %s", value)
	}
}

func bootstrapConfig(alias string) (Config, error) {
	chain, err := resolveNetworkAlias(alias)
	if err != nil {
		return Config{}, err
	}
	endpoint := strings.TrimRight(bootstrapBaseURL, "/") + "/" + chain + "/bootstrap.json"
	response, err := (&http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).Get(endpoint)
	if err != nil {
		return Config{}, fmt.Errorf("read bootstrap for %s: %w", chain, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return Config{}, fmt.Errorf("read bootstrap for %s: HTTP %d", chain, response.StatusCode)
	}
	var document bootstrapDocument
	if err = json.NewDecoder(io.LimitReader(response.Body, maxSourceBytes)).Decode(&document); err != nil {
		return Config{}, fmt.Errorf("decode bootstrap for %s: %w", chain, err)
	}
	var nodes []Node
	for _, seed := range document.Seeds {
		rpc, err := validRPCURL(seed.RPC)
		if err != nil {
			continue
		}
		base, ok := strings.CutSuffix(rpc, "/chain-rpc")
		if !ok || base == "" {
			continue
		}
		id := seed.NodeID
		if !safeID.MatchString(id) {
			id = "bootstrap-rpc"
		}
		nodes = append(nodes, Node{ID: id, RPC: rpc, REST: base + "/chain-api"})
	}
	if len(nodes) == 0 {
		return Config{}, fmt.Errorf("bootstrap for %s contains no usable chain-rpc seed", chain)
	}
	primary := nodes[0]
	for _, node := range nodes[1:] {
		primary.RPCAlternates = append(primary.RPCAlternates, node.RPC)
		primary.RPCAlternateIDs = append(primary.RPCAlternateIDs, node.ID)
	}
	return Config{Incident: alias + "-trace", Chain: chain, PaddingSeconds: 120, RequestDelayMillis: 250, RequireCompleteRPC: true, TimeoutSeconds: 20, Concurrency: 1, Nodes: []Node{primary}}, nil
}

func validRPCURL(value string) (string, error) {
	u, err := url.Parse(strings.TrimRight(value, "/"))
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "http" && u.Scheme != "https") || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("invalid RPC URL")
	}
	return u.String(), nil
}

func networkCollectionArguments(args []string) (Config, int64, int64, error) {
	if len(args) < 2 || len(args) > 3 {
		return Config{}, 0, 0, fmt.Errorf("requires <mainnet|devnet|testnet|RPC> <from> [to]")
	}
	var c Config
	var head int64
	var err error
	if _, aliasErr := resolveNetworkAlias(args[0]); aliasErr == nil {
		c, err = bootstrapConfig(args[0])
		if err == nil {
			head, err = selectVerifiedBootstrapRPC(&c)
		}
	} else {
		c, head, err = directRPCConfig(args[0])
	}
	if err != nil {
		return Config{}, 0, 0, err
	}
	from, err := resolveHeight(args[1], head)
	if err != nil {
		return Config{}, 0, 0, err
	}
	to := head
	if len(args) == 3 {
		if strings.HasPrefix(args[2], "+") {
			delta, parseErr := strconv.ParseInt(strings.TrimPrefix(args[2], "+"), 10, 64)
			if parseErr != nil || delta < 0 || delta > head-from {
				return Config{}, 0, 0, fmt.Errorf("invalid range offset %q", args[2])
			}
			to = from + delta
		} else {
			to, err = resolveHeight(args[2], head)
			if err != nil {
				return Config{}, 0, 0, err
			}
		}
	}
	if to < from {
		return Config{}, 0, 0, fmt.Errorf("end height precedes start height")
	}
	if to-from > 10000 {
		return Config{}, 0, 0, fmt.Errorf("network profile ranges are limited to 10000 blocks")
	}
	return c, from, to, nil
}

func directRPCConfig(rpc string) (Config, int64, error) {
	rpc, err := validRPCURL(rpc)
	if err != nil {
		return Config{}, 0, fmt.Errorf("unknown chain ID or invalid RPC URL: %s", rpc)
	}
	node := Node{ID: "rpc", RPC: rpc}
	if base, ok := strings.CutSuffix(rpc, "/chain-rpc"); ok && base != "" {
		node.REST = base + "/chain-api"
	}
	head, err := latestHeight(node, 20)
	if err != nil {
		return Config{}, 0, fmt.Errorf("resolve RPC HEAD: %w", err)
	}
	chain, err := readChainID(node, 20, head)
	if err != nil {
		return Config{}, 0, fmt.Errorf("verify RPC chain: %w", err)
	}
	return Config{Incident: "rpc-trace", Chain: chain, PaddingSeconds: 120, RequestDelayMillis: 250, RequireCompleteRPC: true, TimeoutSeconds: 20, Concurrency: 1, Nodes: []Node{node}}, head, nil
}

func isNetworkTarget(value string) bool {
	if _, err := resolveNetworkAlias(value); err == nil {
		return true
	}
	_, err := validRPCURL(value)
	return err == nil
}

func selectVerifiedBootstrapRPC(c *Config) (int64, error) {
	node := &c.Nodes[0]
	candidates := append([]string{node.RPC}, node.RPCAlternates...)
	candidateIDs := append([]string{node.ID}, node.RPCAlternateIDs...)
	var last error
	for i, rpc := range candidates {
		probe := *node
		probe.RPC = rpc
		if i < len(candidateIDs) {
			probe.ID = candidateIDs[i]
		}
		base, ok := strings.CutSuffix(rpc, "/chain-rpc")
		if !ok {
			continue
		}
		probe.REST = base + "/chain-api"
		head, err := latestHeight(probe, c.TimeoutSeconds)
		if err == nil {
			err = verifyChainID(probe, c.TimeoutSeconds, head, c.Chain)
		}
		if err != nil {
			last = err
			continue
		}
		probe.RPCAlternates = append(append([]string{}, candidates[i+1:]...), candidates[:i]...)
		probe.RPCAlternateIDs = append(append([]string{}, candidateIDs[i+1:]...), candidateIDs[:i]...)
		*node = probe
		return head, nil
	}
	if last == nil {
		last = fmt.Errorf("no Bootstrap RPC candidates")
	}
	return 0, last
}

func resolveHeight(value string, head int64) (int64, error) {
	if value == "HEAD" {
		if head < 1 {
			return 0, fmt.Errorf("HEAD requires a resolved current height")
		}
		return head, nil
	}
	if strings.HasPrefix(value, "HEAD~") {
		if head < 1 {
			return 0, fmt.Errorf("%s requires a resolved current height", value)
		}
		delta, err := strconv.ParseInt(strings.TrimPrefix(value, "HEAD~"), 10, 64)
		if err != nil || delta < 0 || delta >= head {
			return 0, fmt.Errorf("invalid relative height %q", value)
		}
		return head - delta, nil
	}
	h, err := strconv.ParseInt(value, 10, 64)
	if err != nil || h < 1 || h == math.MaxInt64 {
		return 0, fmt.Errorf("invalid height %q", value)
	}
	return h, nil
}

func verifyChainID(n Node, timeout int, height int64, expected string) error {
	chain, err := readChainID(n, timeout, height)
	if err != nil {
		return err
	}
	if chain != expected {
		return fmt.Errorf("expected %s at height %d, got chain %q", expected, height, chain)
	}
	return nil
}

func readChainID(n Node, timeout int, height int64) (string, error) {
	u, err := url.Parse(strings.TrimRight(n.RPC, "/") + "/block?height=" + strconv.FormatInt(height, 10))
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return "", fmt.Errorf("invalid RPC URL")
	}
	client := http.Client{Timeout: time.Duration(timeout) * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Get(u.String())
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("block HTTP %d", response.StatusCode)
	}
	var body struct {
		Result struct {
			Block struct {
				Header struct {
					ChainID string `json:"chain_id"`
					Height  string `json:"height"`
				} `json:"header"`
			} `json:"block"`
		} `json:"result"`
	}
	if err = json.NewDecoder(io.LimitReader(response.Body, maxSourceBytes)).Decode(&body); err != nil {
		return "", err
	}
	if body.Result.Block.Header.ChainID == "" || body.Result.Block.Header.Height != strconv.FormatInt(height, 10) {
		return "", fmt.Errorf("expected a chain ID at height %d, got chain %q height %q", height, body.Result.Block.Header.ChainID, body.Result.Block.Header.Height)
	}
	return body.Result.Block.Header.ChainID, nil
}
