package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl-test/stand"
)

func TestRunQualificationVerifyOnlyHasNoLaunchOrLease(t *testing.T) {
	dir := t.TempDir()
	profilePath := filepath.Join("..", "..", "environments", "proposed-compatible-devshard-baseline-v8.json")
	profile, err := stand.BindProfile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	compositionPath := filepath.Join(dir, "composition.json")
	fixturePath := filepath.Join(dir, "fixture.json")
	invalidPath := filepath.Join(dir, "invalid.json")
	if err := writeStandDecision(compositionPath, stand.CompositionDecision{Outcome: "launch_completed"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixturePath, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeStandDecision(invalidPath, stand.CompositionDecision{Outcome: "rejected_digest_mismatch"}); err != nil {
		t.Fatal(err)
	}
	evidence := map[string]string{}
	for label, path := range map[string]string{"composition": compositionPath, "fixture": fixturePath, "invalid_digest": invalidPath} {
		contents, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(contents)
		evidence[label] = hex.EncodeToString(sum[:])
	}
	eligibilityPath := filepath.Join(dir, "eligibility.json")
	if err := writeStandDecision(eligibilityPath, stand.CompatibilityDecision{Profile: profile, CompositionReceipt: compositionPath, FixtureReceipt: fixturePath, InvalidDigest: invalidPath, EvidenceSHA256: evidence, Outcome: "eligible_for_independent_acceptance"}); err != nil {
		t.Fatal(err)
	}
	eligibilityBytes, err := os.ReadFile(eligibilityPath)
	if err != nil {
		t.Fatal(err)
	}
	eligibilitySum := sha256.Sum256(eligibilityBytes)
	decisionPath := filepath.Join(dir, "decision.json")
	if err := writeStandDecision(decisionPath, stand.QualificationDecision{SchemaVersion: "1.0.0", DecisionID: "review-v8", Issuer: "independent-reviewer", ReviewReference: "review-receipt", Outcome: "accepted", BaselineStatus: "qualified", SupportedAdapters: []string{"v5"}, UnqualifiedAdapters: []string{"v3", "v4"}, ProfileSHA256: profile.SHA256, EnvironmentID: profile.EnvironmentID, EligibilitySHA256: hex.EncodeToString(eligibilitySum[:]), EvidenceSHA256: evidence}); err != nil {
		t.Fatal(err)
	}
	bindingPath := filepath.Join(dir, "binding.json")
	leaseRoot := filepath.Join(dir, "leases")
	err = run([]string{"--qualification-verify-only", "--receipt", bindingPath, "--qualification-decision", decisionPath, "--eligibility-receipt", eligibilityPath, "--environment-id", profile.EnvironmentID, "--profile", profilePath})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(leaseRoot); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("qualification verification created lease state: %v", err)
	}
	if err := run([]string{"--qualification-verify-only", "--preflight-only", "--environment-id", profile.EnvironmentID, "--profile", profilePath}); err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("accepted conflicting modes: %v", err)
	}
}

func writeStandDecision(path string, value any) error {
	contents, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, append(contents, '\n'), 0o600)
}

func TestRunPersistsProfileBeforeRejectingDigest(t *testing.T) {
	dir := t.TempDir()
	prepared := filepath.Join(dir, "prepared")
	if err := os.MkdirAll(prepared, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared, "config.yaml"), []byte("config\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared, "docker-compose.yml"), []byte("services: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	receipt := filepath.Join(dir, "receipt", "decision.json")
	leaseRoot := filepath.Join(dir, "leases")
	err := run([]string{
		"--prepared-workdir", prepared,
		"--composition-digest", "wrong",
		"--receipt", receipt,
		"--fixture-receipt", filepath.Join(dir, "fixture.json"),
		"--lease-root", leaseRoot,
		"--environment-id", "lab-mock-devshard-testenv-v5",
		"--instance-id", "profile-bound-mismatch",
		"--profile", filepath.Join("..", "..", "environments", "lab-mock-devshard-testenv-v5.json"),
		"false",
	})
	if !errors.Is(err, stand.ErrCompositionDigestMismatch) {
		t.Fatalf("err=%v", err)
	}
	contents, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatal(err)
	}
	var decision stand.CompositionDecision
	if err := json.Unmarshal(contents, &decision); err != nil {
		t.Fatal(err)
	}
	if decision.Profile == nil || decision.Profile.EnvironmentID != "lab-mock-devshard-testenv-v5" || decision.LaunchAttempted || decision.ResourcesCreated {
		t.Fatalf("decision=%+v", decision)
	}
	if _, err := os.Stat(leaseRoot); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("lease root created before digest rejection: %v", err)
	}
}

func TestRunRejectsMismatchedProfileEnvironmentBeforePreflight(t *testing.T) {
	dir := t.TempDir()
	receipt := filepath.Join(dir, "receipt", "decision.json")
	err := run([]string{
		"--prepared-workdir", filepath.Join(dir, "prepared"),
		"--composition-digest", "wrong",
		"--receipt", receipt,
		"--fixture-receipt", filepath.Join(dir, "fixture.json"),
		"--lease-root", filepath.Join(dir, "leases"),
		"--environment-id", "wrong-environment",
		"--instance-id", "profile-environment-mismatch",
		"--profile", filepath.Join("..", "..", "environments", "lab-mock-devshard-testenv-v5.json"),
		"false",
	})
	if err == nil || !strings.Contains(err.Error(), "does not match profile environment") {
		t.Fatalf("err=%v", err)
	}
	if _, err := os.Stat(receipt); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("preflight receipt written before environment rejection: %v", err)
	}
}

func TestRunPreflightOnlyAcceptsFrozenProposedBaselineWithoutLeaseOrLaunch(t *testing.T) {
	dir := t.TempDir()
	prepared := filepath.Join(dir, "prepared")
	if err := os.MkdirAll(prepared, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared, "config.yaml"), []byte("config\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared, "docker-compose.yml"), []byte("services: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	digest, err := stand.PreflightComposition(prepared, "", filepath.Join(dir, "discard.json"))
	if err == nil || digest.ActualDigest == "" {
		t.Fatalf("digest precondition=%+v err=%v", digest, err)
	}
	receipt := filepath.Join(dir, "receipt", "decision.json")
	leaseRoot := filepath.Join(dir, "leases")
	err = run([]string{
		"--preflight-only",
		"--prepared-workdir", prepared,
		"--composition-digest", digest.ActualDigest,
		"--receipt", receipt,
		"--environment-id", "proposed-compatible-devshard-baseline-v1",
		"--profile", filepath.Join("..", "..", "environments", "proposed-compatible-devshard-baseline-v1.json"),
	})
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatal(err)
	}
	var decision stand.CompositionDecision
	if err := json.Unmarshal(contents, &decision); err != nil {
		t.Fatal(err)
	}
	if decision.Outcome != "accepted" || decision.Profile == nil || decision.Profile.EnvironmentID != "proposed-compatible-devshard-baseline-v1" || decision.LaunchAttempted || decision.ResourcesCreated {
		t.Fatalf("decision=%+v", decision)
	}
	if _, err := os.Stat(leaseRoot); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("lease root created by preflight-only: %v", err)
	}
}
