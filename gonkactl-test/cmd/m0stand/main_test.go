package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl-test/stand"
)

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
