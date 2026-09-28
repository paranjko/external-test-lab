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
		return Config{Incident: alias + "-trace", Chain: chain, PaddingSeconds: 120, TimeoutSeconds: 20, Concurrency: 4, Nodes: []Node{{ID: id, RPC: rpc, REST: base + "/chain-api"}}}, nil
	}
	return Config{}, fmt.Errorf("bootstrap for %s contains no usable chain-rpc seed", chain)
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
		return Config{}, 0, 0, fmt.Errorf("requires <mainnet|devnet|testnet> <from> [to]")
	}
	c, err := bootstrapConfig(args[0])
	if err != nil {
		return Config{}, 0, 0, err
	}
	head, err := latestHeight(c.Nodes[0], c.TimeoutSeconds)
	if err != nil {
		return Config{}, 0, 0, fmt.Errorf("resolve %s HEAD: %w", c.Chain, err)
	}
	if err = verifyChainID(c.Nodes[0], c.TimeoutSeconds, head, c.Chain); err != nil {
		return Config{}, 0, 0, fmt.Errorf("verify %s chain: %w", c.Chain, err)
	}
	from, err := resolveHeight(args[1], head)
	if err != nil {
		return Config{}, 0, 0, err
	}
	to := head
	if len(args) == 3 {
		to, err = resolveHeight(args[2], head)
		if err != nil {
			return Config{}, 0, 0, err
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
	u, err := url.Parse(strings.TrimRight(n.RPC, "/") + "/block?height=" + strconv.FormatInt(height, 10))
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return fmt.Errorf("invalid RPC URL")
	}
	client := http.Client{Timeout: time.Duration(timeout) * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Get(u.String())
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("block HTTP %d", response.StatusCode)
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
		return err
	}
	if body.Result.Block.Header.ChainID != expected || body.Result.Block.Header.Height != strconv.FormatInt(height, 10) {
		return fmt.Errorf("expected %s at height %d, got chain %q height %q", expected, height, body.Result.Block.Header.ChainID, body.Result.Block.Header.Height)
	}
	return nil
}
