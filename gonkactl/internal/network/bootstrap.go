package network

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

const maxBootstrapBytes = 262144

var chainIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
var nodeIDPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type BootstrapDescriptor struct {
	Schema  string            `json:"$schema"`
	ChainID string            `json:"chain_id"`
	Genesis BootstrapGenesis  `json:"genesis"`
	Seeds   []BootstrapSeed   `json:"seeds"`
	Brokers []BootstrapBroker `json:"brokers"`
}
type BootstrapGenesis struct {
	SHA256 string `json:"sha256"`
}
type BootstrapSeed struct {
	NodeID string `json:"node_id"`
	RPC    string `json:"rpc"`
	P2P    string `json:"p2p"`
	API    string `json:"api"`
}
type BootstrapBroker struct {
	APIURLs   []string `json:"api_urls"`
	AccessURL string   `json:"access_url"`
}

func ParseBootstrap(raw []byte) (BootstrapDescriptor, error) {
	if len(raw) == 0 || len(raw) > maxBootstrapBytes {
		return BootstrapDescriptor{}, fmt.Errorf("bootstrap document exceeds size limit")
	}
	if !json.Valid(raw) {
		return BootstrapDescriptor{}, fmt.Errorf("invalid bootstrap JSON")
	}
	if err := rejectDuplicateKeys(raw); err != nil {
		return BootstrapDescriptor{}, err
	}
	var value BootstrapDescriptor
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return BootstrapDescriptor{}, err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return BootstrapDescriptor{}, fmt.Errorf("bootstrap has trailing document")
	}
	if err := value.Validate(); err != nil {
		return BootstrapDescriptor{}, err
	}
	return value, nil
}

func (d BootstrapDescriptor) Validate() error {
	if d.Schema != "https://gonka-dev.net/v1.bootstrap.schema.json" || !chainIDPattern.MatchString(d.ChainID) || d.ChainID == "." || d.ChainID == ".." || !digestPattern.MatchString(d.Genesis.SHA256) || len(d.Seeds) < 2 {
		return fmt.Errorf("invalid bootstrap identity")
	}
	ids, rpcs, p2ps := map[string]bool{}, map[string]bool{}, map[string]bool{}
	apis := 0
	for _, seed := range d.Seeds {
		if !nodeIDPattern.MatchString(seed.NodeID) {
			return fmt.Errorf("invalid seed node ID")
		}
		if err := validateEndpoint(seed.RPC, "http", "https"); err != nil {
			return err
		}
		rpc, _ := url.Parse(seed.RPC)
		if strings.TrimRight(rpc.Path, "/") != "/chain-rpc" {
			return fmt.Errorf("seed RPC must use /chain-rpc")
		}
		if err := validateEndpoint(seed.P2P, "tcp"); err != nil {
			return err
		}
		p2p, _ := url.Parse(seed.P2P)
		if p2p.Port() == "" {
			return fmt.Errorf("seed P2P needs port")
		}
		if ids[seed.NodeID] || rpcs[seed.RPC] || p2ps[seed.P2P] {
			return fmt.Errorf("duplicate seed identity or endpoint")
		}
		ids[seed.NodeID], rpcs[seed.RPC], p2ps[seed.P2P] = true, true, true
		if seed.API != "" {
			if err := validateEndpoint(seed.API, "http", "https"); err != nil {
				return err
			}
			apis++
		}
	}
	if apis == 0 {
		return fmt.Errorf("at least one seed API is required")
	}
	for _, broker := range d.Brokers {
		if len(broker.APIURLs) == 0 {
			return fmt.Errorf("broker API URLs required")
		}
		seen := map[string]bool{}
		for _, endpoint := range broker.APIURLs {
			if seen[endpoint] {
				return fmt.Errorf("duplicate broker endpoint")
			}
			seen[endpoint] = true
			if err := validateEndpoint(endpoint, "https"); err != nil {
				return err
			}
		}
		if broker.AccessURL != "" {
			if err := validateEndpoint(broker.AccessURL, "https"); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateEndpoint(raw string, schemes ...string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("unsafe endpoint")
	}
	allowed := false
	for _, scheme := range schemes {
		allowed = allowed || u.Scheme == scheme
	}
	if !allowed {
		return fmt.Errorf("unsupported endpoint scheme")
	}
	if u.Port() != "" {
		if _, err := u.Port(), error(nil); err != nil {
			return fmt.Errorf("invalid endpoint port")
		}
	}
	return nil
}

type bootstrapValidationHandler struct{ deps contracts.Dependencies }

func NewBootstrapDescriptorValidationHandler(deps contracts.Dependencies) contracts.Handler {
	return bootstrapValidationHandler{deps: deps}
}
func (h bootstrapValidationHandler) Execute(_ context.Context, input json.RawMessage) (contracts.Result, error) {
	var request struct {
		Descriptor json.RawMessage `json:"descriptor"`
		Online     bool            `json:"online"`
	}
	if err := json.Unmarshal(input, &request); err != nil {
		return bootstrapResult("invalid_bootstrap_input", 2), nil
	}
	if _, err := ParseBootstrap(request.Descriptor); err != nil {
		return bootstrapResult("bootstrap_validation_failed", 2), nil
	}
	if request.Online {
		return bootstrapResult("bootstrap_online_verification_unavailable", 4), nil
	}
	return contracts.Result{SchemaVersion: 1, Command: "network bootstrap verify", Status: "complete", Phase: "complete", Code: "bootstrap_valid", Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), ExitCode: 0}, nil
}
func bootstrapResult(code string, exit int) contracts.Result {
	return contracts.Result{SchemaVersion: 1, Command: "network bootstrap verify", Status: "failed", Phase: "validate", Code: code, Mutation: "none", SignerState: "unknown", Data: contracts.EmptyResultData(), Error: &contracts.ResultError{Code: code, Message: "Bootstrap descriptor validation failed.", Retryable: false}, ExitCode: exit}
}
