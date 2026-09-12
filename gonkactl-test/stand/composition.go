package stand

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var ErrCompositionDigestMismatch = errors.New("composition digest mismatch")
var ErrFixtureReceiptInvalid = errors.New("fixture receipt invalid")

type CompositionDecision struct {
	ExpectedDigest   string           `json:"expected_digest"`
	ActualDigest     string           `json:"actual_digest"`
	Inputs           []string         `json:"inputs"`
	Profile          *ProfileDecision `json:"profile,omitempty"`
	Outcome          string           `json:"outcome"`
	LaunchAttempted  bool             `json:"launch_attempted"`
	ResourcesCreated bool             `json:"resources_created"`
	LaunchResult     string           `json:"launch_result,omitempty"`
	FixtureReceipt   string           `json:"fixture_receipt,omitempty"`
	Lease            *LeaseDecision   `json:"lease,omitempty"`
}

// ProfileDecision binds the validated environment declaration to the fixture
// preflight receipt. It deliberately records the declaration identity, rather
// than treating an arbitrary launcher command as proof of a baseline decision.
type ProfileDecision struct {
	Path           string `json:"path"`
	SHA256         string `json:"sha256"`
	EnvironmentID  string `json:"environment_id"`
	BaselineStatus string `json:"baseline_status"`
}

// LeaseDecision records lifecycle evidence without exposing the owner token.
// A launch can be complete only after the launcher has released its own lease.
type LeaseDecision struct {
	EnvironmentID string `json:"environment_id"`
	InstanceID    string `json:"instance_id"`
	Path          string `json:"path"`
	Acquired      bool   `json:"acquired"`
	Released      bool   `json:"released"`
	ReleaseError  string `json:"release_error,omitempty"`
}

func MarkCompositionLease(receiptPath string, decision CompositionDecision, lease Lease, released bool, releaseErr error) (CompositionDecision, error) {
	decision.Lease = &LeaseDecision{
		EnvironmentID: lease.EnvironmentID,
		InstanceID:    lease.InstanceID,
		Path:          lease.Path,
		Acquired:      true,
		Released:      released,
	}
	if releaseErr != nil {
		decision.Lease.ReleaseError = releaseErr.Error()
	}
	return decision, writeDecision(receiptPath, decision)
}

// ValidateFixtureReceipt enforces the minimum evidence boundary for a
// successful managed-fixture launch. The fixture owns this JSON; this adapter
// only accepts complete, parseable evidence and never infers missing fields.
func ValidateFixtureReceipt(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("%w: read: %v", ErrFixtureReceiptInvalid, err)
	}
	var r struct {
		Outcomes map[string]struct {
			Outcome string `json:"outcome"`
		} `json:"outcomes"`
		Identity struct {
			ChainID         json.RawMessage `json:"chain_id"`
			GenesisHash     json.RawMessage `json:"genesis_hash"`
			Source          string          `json:"source"`
			FixtureSeedHash string          `json:"fixture_seed_hash"`
		} `json:"identity"`
		Controls map[string]struct {
			Outcome string `json:"outcome"`
		} `json:"controls"`
		TerminalCleanup struct {
			Completed           bool `json:"completed"`
			RemainingContainers int  `json:"remaining_containers"`
			RemainingProcesses  int  `json:"remaining_processes"`
			RemainingPorts      int  `json:"remaining_ports"`
		} `json:"terminal_cleanup"`
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return fmt.Errorf("%w: decode: %v", ErrFixtureReceiptInvalid, err)
	}
	for _, gate := range []string{"SG01", "SG02", "SG03", "SG04", "SG05"} {
		if r.Outcomes[gate].Outcome == "" {
			return fmt.Errorf("%w: missing %s outcome", ErrFixtureReceiptInvalid, gate)
		}
	}
	if len(r.Identity.ChainID) == 0 || len(r.Identity.GenesisHash) == 0 {
		return fmt.Errorf("%w: identity chain_id and genesis_hash are required", ErrFixtureReceiptInvalid)
	}
	if r.Identity.Source == "" || r.Identity.FixtureSeedHash == "" {
		return fmt.Errorf("%w: identity source and fixture_seed_hash are required", ErrFixtureReceiptInvalid)
	}
	if r.Identity.Source != "simulated" && (string(r.Identity.ChainID) == "null" || string(r.Identity.GenesisHash) == "null") {
		return fmt.Errorf("%w: non-simulated identity cannot use null chain_id/genesis_hash", ErrFixtureReceiptInvalid)
	}
	for _, control := range []string{"known_good_baseline", "invalid_digest", "missing_route", "broken_mock"} {
		if r.Controls[control].Outcome == "" {
			return fmt.Errorf("%w: missing controls.%s outcome", ErrFixtureReceiptInvalid, control)
		}
	}
	c := r.TerminalCleanup
	if !c.Completed || c.RemainingContainers != 0 || c.RemainingProcesses != 0 || c.RemainingPorts != 0 {
		return fmt.Errorf("%w: terminal cleanup incomplete", ErrFixtureReceiptInvalid)
	}
	return nil
}

// PreflightComposition hashes exactly the prepared config and Compose files
// that the fixture launch consumes. A mismatch is a terminal pre-launch
// decision: no command, Docker project, port, volume or container is created.
func PreflightComposition(workDir, expectedDigest, receiptPath string) (CompositionDecision, error) {
	return preflightComposition(workDir, expectedDigest, receiptPath, nil)
}

// PreflightCompositionWithProfile binds a validated profile even when the
// declared composition digest is rejected before resource creation.
func PreflightCompositionWithProfile(workDir, expectedDigest, receiptPath string, profile ProfileDecision) (CompositionDecision, error) {
	return preflightComposition(workDir, expectedDigest, receiptPath, &profile)
}

func preflightComposition(workDir, expectedDigest, receiptPath string, profile *ProfileDecision) (CompositionDecision, error) {
	configPath := filepath.Join(workDir, "config.yaml")
	composePath := filepath.Join(workDir, "docker-compose.yml")
	actual, err := compositionDigest(configPath, composePath)
	decision := CompositionDecision{ExpectedDigest: expectedDigest, ActualDigest: actual, Inputs: []string{configPath, composePath}, Profile: profile}
	if err != nil {
		decision.Outcome = "preflight_error"
		if receiptErr := writeDecision(receiptPath, decision); receiptErr != nil {
			return decision, fmt.Errorf("record preflight error: %w", receiptErr)
		}
		return decision, err
	}
	if expectedDigest == "" || expectedDigest != actual {
		decision.Outcome = "rejected_digest_mismatch"
		if receiptErr := writeDecision(receiptPath, decision); receiptErr != nil {
			return decision, fmt.Errorf("record mismatch decision: %w", receiptErr)
		}
		return decision, fmt.Errorf("%w: declared=%q actual=%q", ErrCompositionDigestMismatch, expectedDigest, actual)
	}
	decision.Outcome = "accepted"
	if err := writeDecision(receiptPath, decision); err != nil {
		return decision, err
	}
	return decision, nil
}

// BindProfile validates an M0 environment declaration and returns immutable
// identity fields for the fixture decision. Callers must persist this before
// acquiring a lease or invoking a fixture command.
func BindProfile(path string) (ProfileDecision, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return ProfileDecision{}, fmt.Errorf("read profile: %w", err)
	}
	profile, err := LoadProfile(path)
	if err != nil {
		return ProfileDecision{}, err
	}
	digest := sha256.Sum256(contents)
	return ProfileDecision{
		Path:           path,
		SHA256:         hex.EncodeToString(digest[:]),
		EnvironmentID:  profile.EnvironmentID,
		BaselineStatus: profile.Baseline.Status,
	}, nil
}

// MarkCompositionLaunch records that the wrapper has crossed the pre-launch
// boundary and is about to invoke the command. From this point resource
// creation is possible, so never retain the rejection-only false value.
func MarkCompositionLaunch(receiptPath string, decision CompositionDecision) (CompositionDecision, error) {
	decision.LaunchAttempted = true
	decision.ResourcesCreated = true
	decision.Outcome = "launch_started"
	return decision, writeDecision(receiptPath, decision)
}

// MarkCompositionLaunchResult closes the adapter's decision record. Fixture
// resource and cleanup evidence remains the responsibility of the launched
// harness and is recorded in its receipt.
func MarkCompositionLaunchResult(receiptPath string, decision CompositionDecision, launchErr error) error {
	decision.LaunchAttempted = true
	if launchErr == nil {
		decision.Outcome = "launch_completed"
		decision.LaunchResult = "success"
	} else {
		decision.Outcome = "launch_failed"
		decision.LaunchResult = launchErr.Error()
	}
	return writeDecision(receiptPath, decision)
}

func MarkCompositionFixtureResult(receiptPath, fixtureReceipt string, decision CompositionDecision, launchErr error) error {
	decision.FixtureReceipt = fixtureReceipt
	if launchErr != nil {
		return MarkCompositionLaunchResult(receiptPath, decision, launchErr)
	}
	if err := ValidateFixtureReceipt(fixtureReceipt); err != nil {
		decision.LaunchAttempted = true
		decision.Outcome = "launch_failed"
		decision.LaunchResult = err.Error()
		if writeErr := writeDecision(receiptPath, decision); writeErr != nil {
			return fmt.Errorf("record invalid fixture receipt: %w", writeErr)
		}
		return err
	}
	return MarkCompositionLaunchResult(receiptPath, decision, nil)
}

func compositionDigest(configPath, composePath string) (string, error) {
	config, err := os.ReadFile(configPath)
	if err != nil {
		return "", err
	}
	compose, err := os.ReadFile(composePath)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	for _, input := range []struct {
		name string
		data []byte
	}{{"config.yaml", config}, {"docker-compose.yml", compose}} {
		if _, err := fmt.Fprintf(h, "%s\x00%d\x00", input.name, len(input.data)); err != nil {
			return "", err
		}
		if _, err := h.Write(input.data); err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func writeDecision(path string, decision CompositionDecision) error {
	if path == "" {
		return errors.New("composition receipt path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(decision, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o600)
}
