// Package stand implements the M0 managed-fixture adapter boundary.
package stand

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

var revisionPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)

type Profile struct {
	SchemaVersion   string `json:"schema_version"`
	EnvironmentID   string `json:"environment_id"`
	EnvironmentKind string `json:"environment_kind"`
	Backend         struct {
		Name             string `json:"name"`
		SourceRepository string `json:"source_repository"`
		SourceRevision   string `json:"source_revision"`
		Transport        string `json:"transport"`
	} `json:"backend"`
	LeaseAuthority string `json:"lease_authority"`
	Baseline       struct {
		Status string `json:"status"`
		Reason string `json:"reason"`
	} `json:"baseline"`
	Adapters           []Adapter `json:"adapters"`
	PersistentDataRoot string    `json:"persistent_data_root"`
}

type Adapter struct {
	Protocol            string `json:"protocol"`
	Status              string `json:"status"`
	Reason              string `json:"reason"`
	UnqualifiedContract struct {
		Basis   string   `json:"basis"`
		Unknown []string `json:"unknown"`
	} `json:"unqualified_contract"`
	Health struct {
		Path           string `json:"path"`
		ExpectedStatus int    `json:"expected_status"`
	} `json:"health"`
	Chat struct {
		Path                    string `json:"path"`
		NonStreamExpectedStatus int    `json:"non_stream_expected_status"`
		SSETermination          string `json:"sse_termination"`
		MalformedExpectedStatus int    `json:"malformed_expected_status"`
	} `json:"chat"`
	Negative struct {
		MissingRoutePath           string   `json:"missing_route_path"`
		MissingRouteExpectedStatus int      `json:"missing_route_expected_status"`
		BrokenMockAcceptedOutcomes []string `json:"broken_mock_accepted_outcomes"`
	} `json:"negative"`
}

func LoadProfile(path string) (Profile, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return Profile{}, err
	}
	var profile Profile
	if err := json.Unmarshal(contents, &profile); err != nil {
		return Profile{}, fmt.Errorf("decode profile: %w", err)
	}
	if err := profile.Validate(); err != nil {
		return Profile{}, fmt.Errorf("profile %s: %w", filepath.Base(path), err)
	}
	return profile, nil
}

func (p Profile) Validate() error {
	if p.SchemaVersion != "1.0.0" && p.SchemaVersion != "1.1.0" {
		return fmt.Errorf("unsupported schema version %q", p.SchemaVersion)
	}
	if p.EnvironmentID == "" || p.EnvironmentKind != "lab-mock" {
		return fmt.Errorf("M0 profile must name a lab-mock environment")
	}
	if p.Backend.Name != "devshard-testenv" || !revisionPattern.MatchString(p.Backend.SourceRevision) {
		return fmt.Errorf("exact devshard-testenv source revision is required")
	}
	if p.Backend.Transport != "owned Docker Compose plus loopback HTTP" {
		return fmt.Errorf("unowned or ambiguous transport %q", p.Backend.Transport)
	}
	if p.LeaseAuthority == "" || p.PersistentDataRoot == "" {
		return fmt.Errorf("lease authority and persistent data root are required")
	}
	if p.Baseline.Status != "unqualified" && p.Baseline.Status != "qualified" {
		return fmt.Errorf("unknown baseline status %q", p.Baseline.Status)
	}
	seen := map[string]bool{}
	for _, adapter := range p.Adapters {
		if seen[adapter.Protocol] {
			return fmt.Errorf("duplicate adapter %q", adapter.Protocol)
		}
		seen[adapter.Protocol] = true
		if adapter.Protocol != "v3" && adapter.Protocol != "v4" && adapter.Protocol != "v5" {
			return fmt.Errorf("unexpected protocol %q", adapter.Protocol)
		}
		if adapter.Status != "unqualified" && adapter.Status != "candidate" && adapter.Status != "qualified" {
			return fmt.Errorf("unknown adapter status %q for %s", adapter.Status, adapter.Protocol)
		}
		if adapter.Status == "unqualified" {
			if adapter.Reason == "" {
				return fmt.Errorf("unqualified %s requires an explicit gap reason", adapter.Protocol)
			}
			if p.SchemaVersion == "1.1.0" {
				if adapter.UnqualifiedContract.Basis != "v5_only_fixture" {
					return fmt.Errorf("unqualified %s requires v5_only_fixture evidence basis", adapter.Protocol)
				}
				if err := validateUnknownContract(adapter.Protocol, adapter.UnqualifiedContract.Unknown); err != nil {
					return err
				}
			}
		}
		if adapter.Status == "qualified" && p.Baseline.Status != "qualified" {
			return fmt.Errorf("%s cannot be qualified while baseline is unqualified", adapter.Protocol)
		}
		if adapter.Status == "candidate" && (adapter.Health.Path == "" || adapter.Health.ExpectedStatus < 100) {
			return fmt.Errorf("candidate %s lacks an executable health contract", adapter.Protocol)
		}
		if adapter.Status == "candidate" && (adapter.Chat.Path == "" || adapter.Chat.NonStreamExpectedStatus < 100 || adapter.Chat.SSETermination == "" || adapter.Chat.MalformedExpectedStatus < 100) {
			return fmt.Errorf("candidate %s lacks a complete chat contract", adapter.Protocol)
		}
		if adapter.Status == "candidate" && (adapter.Negative.MissingRoutePath == "" || adapter.Negative.MissingRouteExpectedStatus < 100 || len(adapter.Negative.BrokenMockAcceptedOutcomes) == 0) {
			return fmt.Errorf("candidate %s lacks a complete negative contract", adapter.Protocol)
		}
	}
	if !seen["v3"] || !seen["v4"] || !seen["v5"] {
		return fmt.Errorf("v3/v4/v5 matrix is incomplete")
	}
	return nil
}

func validateUnknownContract(protocol string, unknown []string) error {
	required := map[string]bool{
		"health_route": false, "chat_route": false, "non_stream_status": false,
		"sse_termination": false, "malformed_status": false,
		"missing_route_status": false, "broken_mock_behavior": false,
	}
	for _, field := range unknown {
		seen, ok := required[field]
		if !ok {
			return fmt.Errorf("unqualified %s has unknown gap field %q", protocol, field)
		}
		if seen {
			return fmt.Errorf("unqualified %s repeats gap field %q", protocol, field)
		}
		required[field] = true
	}
	for field, seen := range required {
		if !seen {
			return fmt.Errorf("unqualified %s lacks explicit %s gap", protocol, field)
		}
	}
	return nil
}
