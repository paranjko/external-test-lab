// Package support writes bounded, self-consistent acceptance receipts.
package support

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

type Check struct {
	ID                  string   `json:"id"`
	Status              string   `json:"status"`
	Observed            string   `json:"observed"`
	EvidenceArtifactIDs []string `json:"evidence_artifact_ids"`
}

type Artifact struct {
	ID     string `json:"id"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

var artifactID = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
var testID = regexp.MustCompile(`^[CBJRNGOPDX][0-9]{2}\.(code|lab|sepolia|public)$`)
var commitSHA = regexp.MustCompile(`^[a-f0-9]{40}$`)
var sha256Hex = regexp.MustCompile(`^[a-f0-9]{64}$`)

// WriteArtifact writes one sanitized artifact adjacent to this test's receipt.
// It uses exclusive creation and therefore cannot overwrite another test run.
func WriteArtifact(id string, sanitized []byte) (Artifact, error) {
	if !artifactID.MatchString(id) {
		return Artifact{}, errors.New("invalid artifact ID")
	}
	receiptPath := os.Getenv("GONKACTL_TEST_RECEIPT")
	if receiptPath == "" {
		return Artifact{}, errors.New("GONKACTL_TEST_RECEIPT is required")
	}
	base := strings.TrimSuffix(filepath.Base(receiptPath), filepath.Ext(receiptPath))
	path := filepath.Join(filepath.Dir(receiptPath), base+"-"+id+".artifact")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return Artifact{}, err
	}
	if _, err := file.Write(sanitized); err != nil {
		_ = file.Close()
		return Artifact{}, err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return Artifact{}, err
	}
	if err := file.Close(); err != nil {
		return Artifact{}, err
	}
	return Artifact{ID: id, Path: path, SHA256: digest(sanitized)}, nil
}

// WriteReceipt atomically creates the receipt requested by the gate wrapper.
// Tests supply actual checks/artifacts; this helper never changes outcomes or
// invents evidence for an absent effect.
func WriteReceipt(t testing.TB, started time.Time, status, reason string, checks []Check, artifacts []Artifact) error {
	t.Helper()
	receiptPath := os.Getenv("GONKACTL_TEST_RECEIPT")
	if receiptPath == "" {
		return errors.New("GONKACTL_TEST_RECEIPT is required")
	}
	if !sha256Hex.MatchString(os.Getenv("GONKACTL_WORKING_TREE_SHA256")) {
		return errors.New("GONKACTL_WORKING_TREE_SHA256 is required")
	}
	command := []string{}
	if raw := os.Getenv("GONKACTL_TEST_COMMAND_JSON"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &command); err != nil {
			return fmt.Errorf("invalid GONKACTL_TEST_COMMAND_JSON: %w", err)
		}
	}
	manifest, err := environment(os.Getenv("GONKACTL_TEST_ENV"))
	if err != nil {
		return err
	}
	receipt := map[string]any{
		"schema_version":          1,
		"test_id":                 os.Getenv("GONKACTL_TEST_ID"),
		"status":                  status,
		"reason":                  reason,
		"commit":                  os.Getenv("GONKACTL_EXPECTED_COMMIT"),
		"started_at":              started.UTC().Format(time.RFC3339Nano),
		"ended_at":                time.Now().UTC().Format(time.RFC3339Nano),
		"environment":             manifest.Environment,
		"fixture_manifest_sha256": manifest.FixtureSHA256,
		"command":                 map[string]any{"argv": command, "cwd": os.Getenv("GONKACTL_TEST_CWD")},
		"artifacts":               artifacts,
		"checks":                  checks,
		"test_exists":             true,
		"skipped":                 false,
		"authorization":           authorization(manifest.Kind),
	}
	if err := validateReceipt(receipt); err != nil {
		return err
	}
	encoded, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	return atomicExclusiveWrite(receiptPath, encoded)
}

type environmentInfo struct {
	Kind          string
	FixtureSHA256 string
	Environment   map[string]any
}

func environment(path string) (environmentInfo, error) {
	if path == "" {
		return environmentInfo{}, errors.New("GONKACTL_TEST_ENV is required")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return environmentInfo{}, err
	}
	var value struct {
		Kind                  string `json:"kind"`
		Identity              string `json:"identity"`
		EvidenceMode          string `json:"evidence_mode"`
		FixtureManifestSHA256 string `json:"fixture_manifest_sha256"`
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return environmentInfo{}, err
	}
	if value.Kind == "" || value.Identity == "" || value.EvidenceMode == "" || !sha256Hex.MatchString(value.FixtureManifestSHA256) {
		return environmentInfo{}, errors.New("invalid environment manifest")
	}
	return environmentInfo{Kind: value.Kind, FixtureSHA256: value.FixtureManifestSHA256, Environment: map[string]any{
		"kind": value.Kind, "identity": value.Identity, "evidence_mode": value.EvidenceMode, "manifest_sha256": digest(raw),
	}}, nil
}

func authorization(kind string) map[string]any {
	if kind == "sepolia" || kind == "public_devnet" {
		return map[string]any{"required": true, "scope": "", "record_sha256": nil}
	}
	return map[string]any{"required": false, "scope": "none", "record_sha256": nil}
}

func validateReceipt(receipt map[string]any) error {
	if !testID.MatchString(stringValue(receipt["test_id"])) || !commitSHA.MatchString(stringValue(receipt["commit"])) {
		return fmt.Errorf("invalid receipt identity: test_id=%q commit=%q", stringValue(receipt["test_id"]), stringValue(receipt["commit"]))
	}
	status, reason := stringValue(receipt["status"]), stringValue(receipt["reason"])
	switch status {
	case "planned", "pass", "fail", "not_run", "blocked", "inconclusive":
	default:
		return errors.New("invalid receipt status")
	}
	if reason == "" || stringValue(receipt["started_at"]) == "" || stringValue(receipt["ended_at"]) == "" {
		return errors.New("missing receipt timing or reason")
	}
	artifacts, ok := receipt["artifacts"].([]Artifact)
	if !ok {
		return errors.New("invalid artifacts")
	}
	artifactIDs := map[string]struct{}{}
	for _, artifact := range artifacts {
		if artifact.ID == "" || artifact.Path == "" || !sha256Hex.MatchString(artifact.SHA256) {
			return errors.New("invalid artifact")
		}
		if _, exists := artifactIDs[artifact.ID]; exists {
			return errors.New("duplicate artifact ID")
		}
		artifactIDs[artifact.ID] = struct{}{}
	}
	checks, ok := receipt["checks"].([]Check)
	if !ok {
		return errors.New("invalid checks")
	}
	for _, check := range checks {
		if check.ID == "" || check.Observed == "" || len(check.EvidenceArtifactIDs) == 0 {
			return errors.New("invalid check")
		}
		for _, id := range check.EvidenceArtifactIDs {
			if _, exists := artifactIDs[id]; !exists {
				return errors.New("check references missing artifact")
			}
		}
	}
	if status == "pass" && (reason != "passed" || len(artifacts) < 2 || len(checks) < 1) {
		return errors.New("pass receipt lacks required evidence")
	}
	return nil
}

func atomicExclusiveWrite(path string, value []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".gonkactl-receipt-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(value); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	// Link is an atomic create-only publication on this directory's filesystem;
	// unlike rename it cannot replace an independently created receipt.
	if err := os.Link(tmpName, path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return errors.New("receipt already exists")
		}
		return err
	}
	return nil
}

func digest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}
