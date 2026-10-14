// Package bootstrap maintains public network discovery documents without shell
// helpers or access to a node's private state.
package bootstrap

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

const SchemaURL = "https://gonka-dev.net/v1.bootstrap.schema.json"
const DocumentLimit = 256 * 1024

//go:embed schema.json
var embeddedSchema []byte

type Seed struct {
	NodeID string `json:"node_id"`
	RPC    string `json:"rpc"`
	P2P    string `json:"p2p"`
	API    string `json:"api,omitempty"`
}

type Document struct {
	Schema  string `json:"$schema"`
	ChainID string `json:"chain_id"`
	Genesis struct {
		SHA256 string `json:"sha256"`
	} `json:"genesis"`
	Seeds   []Seed `json:"seeds"`
	Brokers []struct {
		APIURLs   []string `json:"api_urls"`
		AccessURL string   `json:"access_url,omitempty"`
	} `json:"brokers"`
	Software json.RawMessage `json:"software,omitempty"`
}

// DecodeJSON refuses duplicate keys and invalid UTF-8, which encoding/json
// otherwise accepts. A depth bound also applies to untrusted RPC/schema input.
func DecodeJSON(raw []byte, target any) error {
	if !utf8.Valid(raw) {
		return fmt.Errorf("invalid UTF-8")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 128 {
			return fmt.Errorf("JSON nesting exceeds limit")
		}
		t, err := d.Token()
		if err != nil {
			return err
		}
		switch t {
		case json.Delim('{'):
			seen := map[string]bool{}
			for d.More() {
				key, err := d.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return fmt.Errorf("duplicate or invalid JSON key")
				}
				seen[name] = true
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			_, err = d.Token()
			return err
		case json.Delim('['):
			for d.More() {
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
			_, err = d.Token()
			return err
		}
		return nil
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return fmt.Errorf("trailing JSON value")
	}
	return json.Unmarshal(raw, target)
}

type noRemoteSchema struct{}

func (noRemoteSchema) Load(string) (any, error) {
	return nil, fmt.Errorf("external schema reference refused")
}

// Parse uses the published schema when provided, retaining the monitor's
// ability to validate additive schema extensions. Remote references are never
// fetched. The pinned embedded schema is used for local documents.
func Parse(raw, schema []byte) (Document, error) {
	var doc Document
	if len(raw) > DocumentLimit {
		return doc, fmt.Errorf("bootstrap exceeds size limit")
	}
	var value any
	if err := DecodeJSON(raw, &value); err != nil {
		return doc, err
	}
	if schema == nil {
		schema = embeddedSchema
	}
	if len(schema) > DocumentLimit {
		return doc, fmt.Errorf("schema exceeds size limit")
	}
	var definition map[string]any
	if err := DecodeJSON(schema, &definition); err != nil {
		return doc, err
	}
	if definition["$id"] != SchemaURL {
		return doc, fmt.Errorf("schema identity mismatch")
	}
	if err := localReferences(definition); err != nil {
		return doc, err
	}
	c := jsonschema.NewCompiler()
	c.UseLoader(noRemoteSchema{})
	if err := c.AddResource(SchemaURL, definition); err != nil {
		return doc, err
	}
	s, err := c.Compile(SchemaURL)
	if err != nil {
		return doc, fmt.Errorf("invalid bootstrap schema")
	}
	if err := s.Validate(value); err != nil {
		return doc, fmt.Errorf("bootstrap schema validation failed")
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return doc, err
	}
	if err := doc.validate(); err != nil {
		return doc, err
	}
	return doc, nil
}

func localReferences(v any) error {
	switch v := v.(type) {
	case map[string]any:
		for key, child := range v {
			if key == "$ref" || key == "$dynamicRef" {
				ref, ok := child.(string)
				if !ok || !strings.HasPrefix(ref, "#") {
					return fmt.Errorf("external schema reference refused")
				}
			}
			if err := localReferences(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range v {
			if err := localReferences(child); err != nil {
				return err
			}
		}
	}
	return nil
}

func endpoint(raw string, schemes ...string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || strings.ContainsAny(raw, "\r\n\t '\"") {
		return nil, fmt.Errorf("unsafe endpoint")
	}
	allowed := false
	for _, scheme := range schemes {
		allowed = allowed || u.Scheme == scheme
	}
	if !allowed {
		return nil, fmt.Errorf("unsupported endpoint scheme")
	}
	if u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return nil, fmt.Errorf("invalid endpoint port")
		}
	}
	return u, nil
}

func (d Document) validate() error {
	if d.Schema != SchemaURL || d.ChainID == "." || d.ChainID == ".." || len(d.Seeds) < 2 {
		return fmt.Errorf("invalid bootstrap identity")
	}
	ids, rpcs, peers, apis := map[string]bool{}, map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, seed := range d.Seeds {
		rpc, err := endpoint(seed.RPC, "http", "https")
		if err != nil {
			return err
		}
		if strings.TrimRight(rpc.Path, "/") != "/chain-rpc" {
			return fmt.Errorf("RPC requires /chain-rpc")
		}
		peer, err := endpoint(seed.P2P, "tcp")
		if err != nil {
			return err
		}
		if peer.Port() == "" || (peer.Path != "" && peer.Path != "/") {
			return fmt.Errorf("P2P requires an explicit port and no path")
		}
		rpcKey, peerKey := strings.TrimRight(seed.RPC, "/"), strings.TrimRight(seed.P2P, "/")
		if ids[seed.NodeID] || rpcs[rpcKey] || peers[peerKey] {
			return fmt.Errorf("duplicate seed identity or endpoint")
		}
		ids[seed.NodeID], rpcs[rpcKey], peers[peerKey] = true, true, true
		if seed.API != "" {
			if _, err := endpoint(seed.API, "http", "https"); err != nil {
				return err
			}
			key := strings.TrimRight(seed.API, "/")
			if apis[key] {
				return fmt.Errorf("duplicate seed API")
			}
			apis[key] = true
		}
	}
	if len(apis) == 0 {
		return fmt.Errorf("at least one seed API required")
	}
	for _, broker := range d.Brokers {
		seen := map[string]bool{}
		for _, api := range broker.APIURLs {
			if _, err := endpoint(api, "https"); err != nil {
				return err
			}
			if seen[api] {
				return fmt.Errorf("duplicate broker API")
			}
			seen[api] = true
		}
		if broker.AccessURL != "" {
			if _, err := endpoint(broker.AccessURL, "https"); err != nil {
				return err
			}
		}
	}
	if len(d.Software) > 0 {
		var sw struct {
			Deployment struct {
				Repository   string
				ComposeFiles []struct{ Path string } `json:"compose_files"`
			}
			Components map[string]struct {
				Version string
				Upgrade *struct{ Artifact struct{ URL string } }
			}
			OperatorCLI struct {
				Version  string
				Artifact struct{ URL string }
			} `json:"operator_cli"`
		}
		if err := json.Unmarshal(d.Software, &sw); err != nil {
			return err
		}
		if sw.OperatorCLI.Version != sw.Components["node"].Version {
			return fmt.Errorf("operator CLI version differs from node runtime")
		}
		paths := map[string]bool{}
		for _, file := range sw.Deployment.ComposeFiles {
			if paths[file.Path] {
				return fmt.Errorf("duplicate compose path")
			}
			paths[file.Path] = true
		}
		urls := []string{sw.Deployment.Repository, sw.OperatorCLI.Artifact.URL}
		for _, component := range sw.Components {
			if component.Upgrade != nil {
				urls = append(urls, component.Upgrade.Artifact.URL)
			}
		}
		for _, address := range urls {
			if _, err := endpoint(address, "https"); err != nil {
				return err
			}
		}
	}
	return nil
}

// ENV keeps the existing six-variable projection and seed ordering. Software
// belongs only to JSON, never executable environment declarations.
func (d Document) ENV() []byte {
	var first Seed
	var apis []string
	for _, seed := range d.Seeds {
		if seed.API != "" {
			if first.API == "" {
				first = seed
			}
			apis = append(apis, seed.API)
		}
	}
	values := [][2]string{{"SEED_API_URL", first.API}, {"GDC_JOIN_REGISTRATION_ENDPOINTS", strings.Join(apis, ",")}, {"SEED_NODE_RPC_URL", first.RPC}, {"SEED_NODE_P2P_URL", first.P2P}, {"RPC_SERVER_URL_1", d.Seeds[0].RPC}, {"RPC_SERVER_URL_2", d.Seeds[1].RPC}}
	var b strings.Builder
	for _, item := range values {
		fmt.Fprintf(&b, "export %s='%s'\n", item[0], strings.ReplaceAll(item[1], "'", "'\"'\"'"))
	}
	return []byte(b.String())
}
