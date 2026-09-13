package stand

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// QualificationDecision is an externally authored attestation over a frozen
// eligibility receipt. The adapter verifies its bindings but never creates it:
// a non-empty issuer field is provenance, not proof of reviewer independence.
type QualificationDecision struct {
	SchemaVersion       string            `json:"schema_version"`
	DecisionID          string            `json:"decision_id"`
	Issuer              string            `json:"issuer"`
	ReviewReference     string            `json:"review_reference"`
	Outcome             string            `json:"outcome"`
	BaselineStatus      string            `json:"baseline_status"`
	SupportedAdapters   []string          `json:"supported_adapters"`
	UnqualifiedAdapters []string          `json:"unqualified_adapters"`
	ProfileSHA256       string            `json:"profile_sha256"`
	EnvironmentID       string            `json:"environment_id"`
	EligibilitySHA256   string            `json:"eligibility_sha256"`
	EvidenceSHA256      map[string]string `json:"evidence_sha256"`
}

// QualificationBinding is a derived receipt. It proves only that a supplied
// attestation binds the immutable candidate evidence; it is not the
// attestation and does not itself close M0.
type QualificationBinding struct {
	QualificationDecision string          `json:"qualification_decision"`
	DecisionSHA256        string          `json:"decision_sha256"`
	EligibilityReceipt    string          `json:"eligibility_receipt"`
	EligibilitySHA256     string          `json:"eligibility_sha256"`
	Profile               ProfileDecision `json:"profile"`
	Outcome               string          `json:"outcome"`
}

// VerifyQualificationDecision validates an externally supplied decision
// against the frozen eligibility decision and all evidence that eligibility
// consumed. It has no fixture, lease, Docker, or profile-promotion side effect.
func VerifyQualificationDecision(profile ProfileDecision, decisionPath, eligibilityPath, receiptPath string) (QualificationBinding, error) {
	binding := QualificationBinding{QualificationDecision: decisionPath, EligibilityReceipt: eligibilityPath, Profile: profile}
	for _, input := range []string{decisionPath, eligibilityPath, profile.Path} {
		if samePath(input, receiptPath) {
			return binding, fmt.Errorf("qualification receipt must not alias input %q", input)
		}
	}
	if profile.BaselineStatus != "unqualified" || profile.SHA256 == "" || profile.EnvironmentID == "" {
		return binding, fmt.Errorf("initially unqualified profile identity is required")
	}
	decisionBytes, err := os.ReadFile(decisionPath)
	if err != nil {
		return binding, fmt.Errorf("read qualification decision: %w", err)
	}
	decisionSum := sha256.Sum256(decisionBytes)
	binding.DecisionSHA256 = hex.EncodeToString(decisionSum[:])
	var decision QualificationDecision
	if err := json.Unmarshal(decisionBytes, &decision); err != nil {
		return binding, fmt.Errorf("decode qualification decision: %w", err)
	}
	eligibilityBytes, err := os.ReadFile(eligibilityPath)
	if err != nil {
		return binding, fmt.Errorf("read eligibility receipt: %w", err)
	}
	eligibilitySum := sha256.Sum256(eligibilityBytes)
	binding.EligibilitySHA256 = hex.EncodeToString(eligibilitySum[:])
	var eligibility CompatibilityDecision
	if err := json.Unmarshal(eligibilityBytes, &eligibility); err != nil {
		return binding, fmt.Errorf("decode eligibility receipt: %w", err)
	}
	if eligibility.Outcome != "eligible_for_independent_acceptance" || eligibility.Profile.SHA256 != profile.SHA256 || eligibility.Profile.EnvironmentID != profile.EnvironmentID || eligibility.Profile.BaselineStatus != "unqualified" {
		return binding, fmt.Errorf("eligibility receipt is not bound to the initially unqualified profile")
	}
	if decision.SchemaVersion != "1.0.0" || decision.DecisionID == "" || decision.Issuer == "" || decision.ReviewReference == "" || decision.Outcome != "accepted" || decision.BaselineStatus != "qualified" {
		return binding, fmt.Errorf("qualification decision is not an explicit accepted baseline attestation")
	}
	if decision.ProfileSHA256 != profile.SHA256 || decision.EnvironmentID != profile.EnvironmentID || decision.EligibilitySHA256 != binding.EligibilitySHA256 {
		return binding, fmt.Errorf("qualification decision does not bind profile and eligibility receipt")
	}
	if !exactAdapterScope(decision.SupportedAdapters, []string{"v5"}) || !exactAdapterScope(decision.UnqualifiedAdapters, []string{"v3", "v4"}) {
		return binding, fmt.Errorf("qualification decision expands the supported adapter scope")
	}
	for label, expected := range eligibility.EvidenceSHA256 {
		if expected == "" || decision.EvidenceSHA256[label] != expected {
			return binding, fmt.Errorf("qualification decision does not bind %s evidence", label)
		}
	}
	if len(decision.EvidenceSHA256) != len(eligibility.EvidenceSHA256) {
		return binding, fmt.Errorf("qualification decision has unexpected evidence bindings")
	}
	for label, path := range map[string]string{"composition": eligibility.CompositionReceipt, "fixture": eligibility.FixtureReceipt, "invalid_digest": eligibility.InvalidDigest} {
		contents, err := os.ReadFile(path)
		if err != nil {
			return binding, fmt.Errorf("read %s evidence: %w", label, err)
		}
		sum := sha256.Sum256(contents)
		if actual := hex.EncodeToString(sum[:]); actual != eligibility.EvidenceSHA256[label] {
			return binding, fmt.Errorf("%s evidence hash does not match eligibility receipt", label)
		}
	}
	binding.Outcome = "qualified_for_m0_a09"
	if err := writeDecision(receiptPath, binding); err != nil {
		return binding, fmt.Errorf("write qualification binding: %w", err)
	}
	return binding, nil
}

func exactAdapterScope(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	seen := map[string]bool{}
	for _, value := range got {
		if seen[value] {
			return false
		}
		seen[value] = true
	}
	for _, value := range want {
		if !seen[value] {
			return false
		}
	}
	return true
}

func samePath(left, right string) bool {
	leftAbs, leftErr := filepath.Abs(left)
	rightAbs, rightErr := filepath.Abs(right)
	if leftErr != nil || rightErr != nil {
		return false
	}
	leftAbs, rightAbs = filepath.Clean(leftAbs), filepath.Clean(rightAbs)
	if leftAbs == rightAbs {
		return true
	}
	// A receipt path can be a hard link or a symlink. Stat follows either one
	// and SameFile catches the hard-link case before writeDecision truncates it.
	leftInfo, leftStatErr := os.Stat(leftAbs)
	rightInfo, rightStatErr := os.Stat(rightAbs)
	if leftStatErr == nil && rightStatErr == nil && os.SameFile(leftInfo, rightInfo) {
		return true
	}
	// When the output itself does not yet exist, a symlinked parent can still
	// resolve it onto an input. Resolve that parent before accepting a new path.
	resolvedParent, parentErr := filepath.EvalSymlinks(filepath.Dir(rightAbs))
	if parentErr != nil {
		return false
	}
	resolvedRight := filepath.Join(resolvedParent, filepath.Base(rightAbs))
	resolvedLeft, leftResolveErr := filepath.EvalSymlinks(leftAbs)
	return leftResolveErr == nil && filepath.Clean(resolvedLeft) == filepath.Clean(resolvedRight)
}
