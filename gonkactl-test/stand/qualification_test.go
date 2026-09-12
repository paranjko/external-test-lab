package stand

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifyQualificationDecisionBindsFrozenEligibilityAndFailsClosed(t *testing.T) {
	dir := t.TempDir()
	profile := ProfileDecision{Path: filepath.Join(dir, "profile.json"), SHA256: "profile-sha", EnvironmentID: "proposed-v8", BaselineStatus: "unqualified"}
	if err := os.WriteFile(profile.Path, []byte("profile"), 0o600); err != nil {
		t.Fatal(err)
	}
	compositionPath := filepath.Join(dir, "composition.json")
	fixturePath := filepath.Join(dir, "fixture.json")
	invalidPath := filepath.Join(dir, "invalid.json")
	if err := writeDecision(compositionPath, CompositionDecision{Outcome: "launch_completed"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixturePath, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeDecision(invalidPath, CompositionDecision{Outcome: "rejected_digest_mismatch"}); err != nil {
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
	eligibility := CompatibilityDecision{Profile: profile, CompositionReceipt: compositionPath, FixtureReceipt: fixturePath, InvalidDigest: invalidPath, EvidenceSHA256: evidence, Outcome: "eligible_for_independent_acceptance"}
	if err := writeDecision(eligibilityPath, eligibility); err != nil {
		t.Fatal(err)
	}
	eligibilityBytes, err := os.ReadFile(eligibilityPath)
	if err != nil {
		t.Fatal(err)
	}
	eligibilitySum := sha256.Sum256(eligibilityBytes)
	decision := QualificationDecision{SchemaVersion: "1.0.0", DecisionID: "review-v8", Issuer: "independent-reviewer", ReviewReference: "review-receipt", Outcome: "accepted", BaselineStatus: "qualified", SupportedAdapters: []string{"v5"}, UnqualifiedAdapters: []string{"v3", "v4"}, ProfileSHA256: profile.SHA256, EnvironmentID: profile.EnvironmentID, EligibilitySHA256: hex.EncodeToString(eligibilitySum[:]), EvidenceSHA256: evidence}
	decisionPath := filepath.Join(dir, "decision.json")
	if err := writeDecision(decisionPath, decision); err != nil {
		t.Fatal(err)
	}
	bindingPath := filepath.Join(dir, "binding.json")
	binding, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, bindingPath)
	if err != nil || binding.Outcome != "qualified_for_m0_a09" {
		t.Fatalf("binding=%+v err=%v", binding, err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, decisionPath); err == nil || !strings.Contains(err.Error(), "must not alias") {
		t.Fatalf("accepted output alias: %v", err)
	}
	symlinkAlias := filepath.Join(dir, "decision-alias.json")
	if err := os.Symlink(decisionPath, symlinkAlias); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, symlinkAlias); err == nil || !strings.Contains(err.Error(), "must not alias") {
		t.Fatalf("accepted symlink output alias: %v", err)
	}
	hardLinkAlias := filepath.Join(dir, "eligibility-alias.json")
	if err := os.Link(eligibilityPath, hardLinkAlias); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, hardLinkAlias); err == nil || !strings.Contains(err.Error(), "must not alias") {
		t.Fatalf("accepted hard-link output alias: %v", err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, profile.Path); err == nil || !strings.Contains(err.Error(), "must not alias") {
		t.Fatalf("accepted profile output alias: %v", err)
	}
	decision.SupportedAdapters = []string{"v3", "v5"}
	if err := writeDecision(decisionPath, decision); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, filepath.Join(dir, "overclaim.json")); err == nil || !strings.Contains(err.Error(), "supported adapter scope") {
		t.Fatalf("accepted v3 overclaim: %v", err)
	}
	decision.SupportedAdapters = []string{"v5"}
	decision.EvidenceSHA256 = map[string]string{"composition": evidence["composition"]}
	if err := writeDecision(decisionPath, decision); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, filepath.Join(dir, "missing-evidence.json")); err == nil || !strings.Contains(err.Error(), "does not bind") {
		t.Fatalf("accepted missing evidence binding: %v", err)
	}
	decision.EvidenceSHA256 = evidence
	if err := writeDecision(decisionPath, decision); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixturePath, []byte("tampered"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyQualificationDecision(profile, decisionPath, eligibilityPath, filepath.Join(dir, "tampered.json")); err == nil || !strings.Contains(err.Error(), "hash does not match") {
		t.Fatalf("accepted tampered fixture evidence: %v", err)
	}
}
