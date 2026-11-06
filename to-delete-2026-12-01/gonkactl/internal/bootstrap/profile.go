package bootstrap

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"
)

type Artifact struct {
	URL        string `json:"url"`
	SHA256     string `json:"sha256"`
	Format     string `json:"format"`
	Executable string `json:"executable"`
}
type Component struct {
	Version string `json:"version"`
	Image   string `json:"image"`
	Commit  string `json:"commit,omitempty"`
	Upgrade *struct {
		Name     string   `json:"name"`
		Artifact Artifact `json:"artifact"`
	} `json:"upgrade,omitempty"`
}
type Software struct {
	SchemaVersion int    `json:"schema_version"`
	Platform      string `json:"platform"`
	Accelerator   string `json:"accelerator"`
	Deployment    struct {
		Repository   string `json:"repository"`
		Commit       string `json:"commit"`
		ComposeFiles []struct {
			Path   string `json:"path"`
			SHA256 string `json:"sha256"`
		} `json:"compose_files"`
	} `json:"deployment"`
	Components  map[string]Component `json:"components"`
	OperatorCLI struct {
		Version  string   `json:"version"`
		Artifact Artifact `json:"artifact"`
	} `json:"operator_cli"`
	Model json.RawMessage `json:"model"`
}

var lockKey = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)
var commitID = regexp.MustCompile(`^[0-9a-f]{40}$`)

// ParseProfile accepts literal KEY=VALUE lock files, not shell programs. No
// expansion, command invocation, sourcing or environment lookup occurs.
func ParseProfile(raw []byte) (map[string]string, error) {
	if len(raw) > DocumentLimit || !utf8.Valid(raw) {
		return nil, fmt.Errorf("invalid profile encoding or size")
	}
	profile := map[string]string{}
	for number, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || !lockKey.MatchString(key) || value == "" {
			return nil, fmt.Errorf("invalid profile assignment at line %d", number+1)
		}
		if _, exists := profile[key]; exists {
			return nil, fmt.Errorf("duplicate profile key %s", key)
		}
		if strings.ContainsAny(value, "$`\\;\x00\r\n") {
			return nil, fmt.Errorf("nonliteral profile value at line %d", number+1)
		}
		if strings.HasPrefix(value, "'") || strings.HasPrefix(value, `"`) {
			if len(value) < 2 || value[len(value)-1] != value[0] {
				return nil, fmt.Errorf("unterminated profile quote")
			}
			value = value[1 : len(value)-1]
		}
		if strings.ContainsAny(value, "'\"") {
			return nil, fmt.Errorf("unsupported profile quoting")
		}
		profile[key] = value
	}
	if profile["LAB_CANDIDATE"] == "true" {
		return nil, fmt.Errorf("unqualified candidate profile cannot define public bootstrap software")
	}
	return profile, nil
}

var imageRoles = map[string]string{
	"INFERENCED_IMAGE": "node", "DAPI_IMAGE": "api", "TMKMS_IMAGE": "tmkms",
	"MLNODE_GENERIC_IMAGE": "mlnode", "POSTGRES_IMAGE": "payload-postgres",
	"EDGE_API_IMAGE": "edge-api", "VERSIOND_IMAGE": "versiond", "VERSIOND_ROUTER_IMAGE": "versiond-router",
	"PROXY_IMAGE": "proxy", "PROXY_POLICY_IMAGE": "proxy-policy", "MLNODE_PROXY_IMAGE": "inference-proxy",
	"EXPLORER_IMAGE": "explorer", "CADDY_IMAGE": "caddy", "GRAFANA_IMAGE": "grafana",
	"NODE_EXPORTER_IMAGE": "node-exporter", "CADVISOR_IMAGE": "cadvisor", "BRIDGE_IMAGE": "bridge",
}

func imageVersion(image string) (string, error) {
	if _, err := parseImage(image); err != nil {
		return "", err
	}
	name, digest, _ := strings.Cut(image, "@")
	if colon := strings.LastIndex(name, ":"); colon > strings.LastIndex(name, "/") {
		return name[colon+1:], nil
	}
	return strings.TrimPrefix(digest, "sha256:"), nil
}

// ApplyProfile overlays only explicitly supplied release fields on a complete
// approved recipe. Model, service layers, accelerator and Compose ordering are
// retained, not invented. A changed deployment commit refreshes every Compose
// digest from its immutable GitHub source before returning a candidate.
func (t *Transport) ApplyProfile(ctx context.Context, base Document, raw []byte) (Document, error) {
	profile, err := ParseProfile(raw)
	if err != nil {
		return Document{}, err
	}
	baseBytes, err := json.Marshal(base)
	if err != nil {
		return Document{}, err
	}
	if _, err := Parse(baseBytes, nil); err != nil {
		return Document{}, fmt.Errorf("profile requires a valid base bootstrap")
	}
	if len(base.Software) == 0 {
		return Document{}, fmt.Errorf("release profile requires a complete base software recipe")
	}
	var software Software
	if err := DecodeJSON(base.Software, &software); err != nil {
		return Document{}, err
	}
	if profile["PROFILE_SCOPE"] != "existing-host-stack" || software.Platform != "linux/amd64" || software.Accelerator != "cuda" {
		return Document{}, fmt.Errorf("this release profile overlay supports existing-host-stack linux/amd64 CUDA recipes only")
	}
	for _, key := range []string{"GONKA_REPOSITORY", "GONKA_COMMIT", "GONKA_RELEASE", "DAPI_SOURCE_REF", "DAPI_COMMIT", "INFERENCED_IMAGE", "DAPI_IMAGE", "TMKMS_IMAGE", "MLNODE_GENERIC_IMAGE", "INFERENCED_OPERATOR_URL_LINUX_AMD64", "INFERENCED_OPERATOR_SHA256_LINUX_AMD64"} {
		if profile[key] == "" {
			return Document{}, fmt.Errorf("profile is missing %s", key)
		}
	}
	if !commitID.MatchString(profile["GONKA_COMMIT"]) || !commitID.MatchString(profile["DAPI_COMMIT"]) {
		return Document{}, fmt.Errorf("profile requires immutable source commits")
	}
	if !strings.HasPrefix(profile["DAPI_SOURCE_REF"], "release/v") {
		return Document{}, fmt.Errorf("profile DAPI source must identify an explicit release version")
	}
	for key, value := range profile {
		if key == "PROXY_ROUTER_IMAGE" {
			if value != profile["PROXY_IMAGE"] {
				return Document{}, fmt.Errorf("conflicting proxy router images")
			}
			continue
		}
		role, known := imageRoles[key]
		if !known {
			if strings.HasSuffix(key, "_IMAGE") {
				return Document{}, fmt.Errorf("unsupported profile image role %s", key)
			}
			continue
		}
		version, err := imageVersion(value)
		if err != nil {
			return Document{}, fmt.Errorf("profile image %s is not pinned", key)
		}
		component := software.Components[role]
		component.Image, component.Version = value, version
		software.Components[role] = component
	}
	for _, runtime := range []struct{ role, prefix, version, commit, binary string }{
		{"node", "INFERENCED", profile["GONKA_RELEASE"], profile["GONKA_COMMIT"], "inferenced"},
		{"api", "DAPI", strings.TrimPrefix(profile["DAPI_SOURCE_REF"], "release/v"), profile["DAPI_COMMIT"], "decentralized-api"},
	} {
		component := software.Components[runtime.role]
		component.Version, component.Commit, component.Upgrade = runtime.version, runtime.commit, nil
		address, digest := profile[runtime.prefix+"_UPGRADE_URL"], profile[runtime.prefix+"_UPGRADE_SHA256"]
		if address != "" || digest != "" {
			component.Upgrade = &struct {
				Name     string   `json:"name"`
				Artifact Artifact `json:"artifact"`
			}{profile["UPGRADE_PLAN_NAME"], Artifact{address, digest, "zip", runtime.binary}}
		} else {
			version, _ := imageVersion(component.Image)
			if strings.TrimPrefix(version, "v") != strings.TrimPrefix(runtime.version, "v") {
				return Document{}, fmt.Errorf("runtime %s needs an explicit upgrade artifact", runtime.role)
			}
		}
		software.Components[runtime.role] = component
	}
	software.OperatorCLI.Version = profile["GONKA_RELEASE"]
	software.OperatorCLI.Artifact = Artifact{profile["INFERENCED_OPERATOR_URL_LINUX_AMD64"], profile["INFERENCED_OPERATOR_SHA256_LINUX_AMD64"], "zip", "inferenced"}
	if software.Deployment.Repository != profile["GONKA_REPOSITORY"] || software.Deployment.Commit != profile["GONKA_COMMIT"] {
		repository := strings.TrimSuffix(profile["GONKA_REPOSITORY"], ".git")
		if !strings.HasPrefix(repository, "https://github.com/") {
			return Document{}, fmt.Errorf("Compose refresh requires an explicit GitHub source repository")
		}
		path := strings.TrimPrefix(repository, "https://github.com/")
		if parts := strings.Split(path, "/"); len(parts) != 2 || !repositoryPath.MatchString(path) {
			return Document{}, fmt.Errorf("invalid Compose source repository")
		}
		for index, file := range software.Deployment.ComposeFiles {
			address := "https://raw.githubusercontent.com/" + path + "/" + profile["GONKA_COMMIT"] + "/" + file.Path
			body, err := t.Get(ctx, address, DocumentLimit)
			if err != nil {
				return Document{}, fmt.Errorf("cannot refresh pinned Compose %s: %w", file.Path, err)
			}
			if len(body) == 0 {
				return Document{}, fmt.Errorf("empty pinned Compose file")
			}
			digest := sha256.Sum256(body)
			software.Deployment.ComposeFiles[index].SHA256 = hex.EncodeToString(digest[:])
		}
		software.Deployment.Repository, software.Deployment.Commit = profile["GONKA_REPOSITORY"], profile["GONKA_COMMIT"]
	}
	encoded, err := json.Marshal(software)
	if err != nil {
		return Document{}, err
	}
	result := base
	result.Software = encoded
	encoded, err = json.Marshal(result)
	if err != nil {
		return Document{}, err
	}
	return Parse(encoded, nil)
}
