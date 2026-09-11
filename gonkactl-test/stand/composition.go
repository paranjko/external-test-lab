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

type CompositionDecision struct {
	ExpectedDigest   string   `json:"expected_digest"`
	ActualDigest     string   `json:"actual_digest"`
	Inputs           []string `json:"inputs"`
	Outcome          string   `json:"outcome"`
	LaunchAttempted  bool     `json:"launch_attempted"`
	ResourcesCreated bool     `json:"resources_created"`
	LaunchResult     string   `json:"launch_result,omitempty"`
}

// PreflightComposition hashes exactly the prepared config and Compose files
// that the fixture launch consumes. A mismatch is a terminal pre-launch
// decision: no command, Docker project, port, volume or container is created.
func PreflightComposition(workDir, expectedDigest, receiptPath string) (CompositionDecision, error) {
	configPath := filepath.Join(workDir, "config.yaml")
	composePath := filepath.Join(workDir, "docker-compose.yml")
	actual, err := compositionDigest(configPath, composePath)
	decision := CompositionDecision{ExpectedDigest: expectedDigest, ActualDigest: actual, Inputs: []string{configPath, composePath}}
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

func MarkCompositionLaunch(receiptPath string, decision CompositionDecision) error {
	decision.LaunchAttempted = true
	decision.Outcome = "launch_started"
	return writeDecision(receiptPath, decision)
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
