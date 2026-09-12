package stand

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPreflightCompositionBindsExactPreparedInputsAndRejectsMismatch(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte("config\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), []byte("services: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	digest, err := compositionDigest(filepath.Join(dir, "config.yaml"), filepath.Join(dir, "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := PreflightComposition(dir, digest, filepath.Join(dir, "accepted.json"))
	if err != nil || accepted.Outcome != "accepted" || accepted.LaunchAttempted {
		t.Fatalf("accepted=%+v err=%v", accepted, err)
	}
	rejected, err := PreflightComposition(dir, "bad", filepath.Join(dir, "rejected.json"))
	if !errors.Is(err, ErrCompositionDigestMismatch) || rejected.Outcome != "rejected_digest_mismatch" || rejected.LaunchAttempted || rejected.ResourcesCreated {
		t.Fatalf("rejected=%+v err=%v", rejected, err)
	}
}

func TestBindProfileAndPreflightPersistProfileOnDigestMismatch(t *testing.T) {
	profilePath := filepath.Join("..", "environments", "lab-mock-devshard-testenv-v5.json")
	contents, err := os.ReadFile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	profile, err := BindProfile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256(contents)
	if profile.SHA256 != hex.EncodeToString(want[:]) || profile.EnvironmentID != "lab-mock-devshard-testenv-v5" || profile.BaselineStatus != "unqualified" {
		t.Fatalf("profile=%+v", profile)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte("config\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), []byte("services: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	receipt := filepath.Join(dir, "decision.json")
	decision, err := PreflightCompositionWithProfile(dir, "wrong", receipt, profile)
	if !errors.Is(err, ErrCompositionDigestMismatch) || decision.Profile == nil || decision.Profile.SHA256 != profile.SHA256 || decision.LaunchAttempted || decision.ResourcesCreated {
		t.Fatalf("decision=%+v err=%v", decision, err)
	}
}

func TestMarkCompositionLaunchSeparatesAcceptedLaunchFromRejectedPreflight(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "launch.json")
	started, err := MarkCompositionLaunch(path, CompositionDecision{Outcome: "accepted"})
	if err != nil {
		t.Fatal(err)
	}
	if !started.LaunchAttempted || !started.ResourcesCreated || started.Outcome != "launch_started" {
		t.Fatalf("launch decision=%+v", started)
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(contents), `"resources_created": true`) {
		t.Fatalf("launch receipt omitted resource boundary: %s", contents)
	}
}

func TestValidateFixtureReceiptRequiresCompleteEvidence(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "fixture.json")
	valid := `{"outcomes":{"SG01":{"outcome":"passed"},"SG02":{"outcome":"passed"},"SG03":{"outcome":"passed"},"SG04":{"outcome":"passed"},"SG05":{"outcome":"passed"}},"identity":{"chain_id":null,"genesis_hash":null,"source":"simulated","fixture_seed_hash":"seed"},"controls":{"known_good_baseline":{"outcome":"passed"},"invalid_digest":{"outcome":"rejected"},"missing_route":{"outcome":"rejected"},"broken_mock":{"outcome":"rejected"}},"terminal_cleanup":{"completed":true,"remaining_containers":0,"remaining_processes":0,"remaining_ports":0}}`
	if err := os.WriteFile(path, []byte(valid), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateFixtureReceipt(path); err != nil {
		t.Fatal(err)
	}
	nonSimulated := strings.Replace(valid, `"source":"simulated"`, `"source":"real"`, 1)
	if err := os.WriteFile(path, []byte(nonSimulated), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateFixtureReceipt(path); !errors.Is(err, ErrFixtureReceiptInvalid) {
		t.Fatalf("accepted non-simulated null identity: %v", err)
	}
	for _, incomplete := range []string{`{}`, `{"outcomes":{"SG01":{"outcome":"passed"}}}`, `{"outcomes":{},"identity":{},"controls":{},"terminal_cleanup":{"completed":false}}`} {
		if err := os.WriteFile(path, []byte(incomplete), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := ValidateFixtureReceipt(path); !errors.Is(err, ErrFixtureReceiptInvalid) {
			t.Fatalf("receipt=%s err=%v", incomplete, err)
		}
	}
}

func TestMarkCompositionLeasePreservesLifecycleWithoutToken(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "receipt.json")
	decision := CompositionDecision{Outcome: "accepted"}
	lease := Lease{EnvironmentID: "lab-mock", InstanceID: "m0-a09", Token: "secret", Path: filepath.Join(dir, "lease.json")}
	if _, err := MarkCompositionLease(path, decision, lease, true, nil); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(contents), lease.Token) || !strings.Contains(string(contents), `"released": true`) {
		t.Fatalf("receipt does not safely preserve lease lifecycle: %s", contents)
	}
}
