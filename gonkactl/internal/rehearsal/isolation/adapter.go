package isolation

import (
	"context"
	"errors"
	"regexp"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// ProcessRunner and ResourceInspector are injectable boundaries. Production
// wiring may provide an executor; tests use fakes and never touch a daemon.
type ProcessRunner interface {
	Run(context.Context, Command) (stdout, stderr []byte, exitCode int, err error)
}
type ResourceInspector interface {
	Inspect(context.Context, []string) ([]Resource, error)
}

type ProbeDomain string

const (
	Host                 ProbeDomain = "host"
	LAN                  ProbeDomain = "lan"
	Internet             ProbeDomain = "internet"
	IPv6                 ProbeDomain = "ipv6"
	DNS                  ProbeDomain = "dns"
	StoredProductionURLs ProbeDomain = "stored_production_urls"
)

var requiredProbes = [...]ProbeDomain{Host, LAN, Internet, IPv6, DNS, StoredProductionURLs}

func RequiredProbeDomains() []ProbeDomain { return append([]ProbeDomain(nil), requiredProbes[:]...) }

type ProbeResult struct {
	Domain         ProbeDomain
	Isolated       bool
	Evidence       []byte
	EvidenceDigest string
	RunID          string
	BindingDigest  string
	RuntimeID      string
	Phase          ProbePhase
}

type ProbePhase string

const (
	Launch  ProbePhase = "launch"
	Handoff ProbePhase = "handoff"
)

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

var ErrProbeIncomplete = errors.New("isolation probe evidence incomplete or failed")

// ValidateProbes must be applied both at launch and handoff. A missing probe,
// failed isolation assertion, or absent evidence digest blocks qualification.
// ValidateProbeEvidence checks evidence consistency only; it cannot prove
// network isolation from a caller-provided assertion or replace real probes.
func ValidateProbeEvidence(binding contract.RunBinding, runtimeID string, phase ProbePhase, results []ProbeResult) error {
	if err := contract.ValidateBinding(binding); err != nil {
		return errors.Join(ErrProbeIncomplete, err)
	}
	if binding.RunID == "" || runtimeID == "" || (phase != Launch && phase != Handoff) || len(results) != len(requiredProbes) {
		return ErrProbeIncomplete
	}
	identityBound := false
	for _, identity := range binding.RuntimeIdentities {
		if identity == runtimeID {
			identityBound = true
			break
		}
	}
	if !identityBound {
		return ErrProbeIncomplete
	}
	digest, err := contract.Digest(binding)
	if err != nil {
		return err
	}
	seen := map[ProbeDomain]bool{}
	for _, p := range results {
		known := false
		for _, d := range requiredProbes {
			if p.Domain == d {
				known = true
				break
			}
		}
		if !known || seen[p.Domain] || !p.Isolated || len(p.Evidence) == 0 || !digestPattern.MatchString(p.EvidenceDigest) || p.EvidenceDigest != contract.PayloadDigest(p.Evidence) || p.RunID != binding.RunID || p.BindingDigest != digest || p.RuntimeID != runtimeID || p.Phase != phase {
			return ErrProbeIncomplete
		}
		seen[p.Domain] = true
	}
	return nil
}
