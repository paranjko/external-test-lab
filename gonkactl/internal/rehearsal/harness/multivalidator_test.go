package harness

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func multiFixture(t *testing.T, powers []int64, signerIDs []string) (contract.RunBinding, []ConfiguredNode, ValidatorSnapshotDocument, map[string]bool) {
	t.Helper()
	binding := testBinding("multi-run")
	artifact := strings.Repeat("d", 64)
	binding.RuntimeIdentities = map[string]string{"recovery_binary": artifact}
	bindingDigest, err := contract.Digest(binding)
	if err != nil {
		t.Fatal(err)
	}
	setHash, setEvidence := strings.Repeat("a", 64), strings.Repeat("b", 64)
	members := make([]ValidatorMember, len(powers))
	for i, power := range powers {
		members[i] = ValidatorMember{ValidatorID: string(rune('v' + i)), VotingPower: power}
	}
	proofs := make([]SignerProof, len(signerIDs))
	verified := map[string]bool{setEvidence: true}
	for i, id := range signerIDs {
		evidence := strings.Repeat(string(rune('c'+i)), 64)
		proofs[i] = SignerProof{ValidatorID: id, EvidenceDigest: evidence}
		verified[evidence] = true
	}
	payload := ValidatorSnapshot{SchemaVersion: MultiValidatorSchemaVersion, RunID: binding.RunID, BindingDigest: bindingDigest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, ArtifactDigest: artifact, Height: binding.Heights.FirstRepaired, SetHash: setHash, Members: members, NodeIdentities: []NodeIdentity{{NodeID: "n1", ValidatorID: "v"}, {NodeID: "n2", ValidatorID: "w"}, {NodeID: "observer"}}, SignerProofs: proofs, SetEvidenceDigest: setEvidence}
	document := ValidatorSnapshotDocument{Payload: payload, EvidenceDigest: SnapshotEvidenceDigest(payload)}
	verified[document.EvidenceDigest] = true
	return binding, []ConfiguredNode{{NodeID: "n1"}, {NodeID: "n2"}, {NodeID: "observer"}}, document, verified
}

func refreshSnapshot(d *ValidatorSnapshotDocument, registry map[string]bool) {
	d.EvidenceDigest = SnapshotEvidenceDigest(d.Payload)
	registry[d.EvidenceDigest] = true
}

func replayFixture(t *testing.T, binding contract.RunBinding, active ValidatorSnapshotDocument) (LateReplayDocument, map[string]bool) {
	t.Helper()
	bindingDigest, err := contract.Digest(binding)
	if err != nil {
		t.Fatal(err)
	}
	proof := LateReplayProof{SchemaVersion: MultiValidatorSchemaVersion, RunID: binding.RunID, BindingDigest: bindingDigest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, ArtifactDigest: active.Payload.ArtifactDigest, ValidatorSetHash: active.Payload.SetHash, ValidatorID: "w", FromHeight: binding.Heights.FirstRepaired, ToHeight: 12, ReplayMode: "saved-block-replay", BlockID: "block-12", AppHash: "app-12", SourceEvidenceDigest: strings.Repeat("e", 64)}
	doc := LateReplayDocument{Payload: proof, EvidenceDigest: LateReplayEvidenceDigest(proof)}
	return doc, map[string]bool{active.EvidenceDigest: true, active.Payload.SetEvidenceDigest: true, doc.EvidenceDigest: true, proof.SourceEvidenceDigest: true}
}

func TestValidateMultiValidatorUsesFullSetPowerAndDistinctSignerIdentities(t *testing.T) {
	b, n, s, v := multiFixture(t, []int64{40, 35, 25}, []string{"v", "w"})
	result, err := ValidateMultiValidator(b, n, s, 2, b.Heights.FirstRepaired, s.Payload.SetHash, s.Payload.ArtifactDigest, v)
	if err != nil {
		t.Fatal(err)
	}
	if !result.ConsistencyChecked || result.ConfiguredNodeCount != 3 || result.ConfiguredActiveValidatorCount != 2 || result.ValidatorSetMemberCount != 3 || result.TotalVotingPower != 100 || result.SignedVotingPower != 75 {
		t.Fatalf("wrong arithmetic summary: %+v", result)
	}
	if !strings.Contains(result.Reason, "cryptography is not verified") {
		t.Fatalf("result overstates proof: %q", result.Reason)
	}
}

func TestValidateMultiValidatorFailClosedMatrix(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*contract.RunBinding, *[]ConfiguredNode, *ValidatorSnapshotDocument, map[string]bool, *string)
	}{
		{"duplicate local validator identity", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.NodeIdentities[1].ValidatorID = "v"
			refreshSnapshot(s, v)
		}},
		{"missing node identity observation", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.NodeIdentities = s.Payload.NodeIdentities[:2]
			refreshSnapshot(s, v)
		}},
		{"unknown signer identity substitution", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.SignerProofs[0].ValidatorID = "observer"
			refreshSnapshot(s, v)
		}},
		{"duplicate signer identity", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.SignerProofs = append(s.Payload.SignerProofs, s.Payload.SignerProofs[0])
			refreshSnapshot(s, v)
		}},
		{"duplicate evidence cannot impersonate two signers", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.SignerProofs[1].EvidenceDigest = s.Payload.SignerProofs[0].EvidenceDigest
			refreshSnapshot(s, v)
		}},
		{"missing full-set evidence", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, _ map[string]bool, _ *string) {
			s.Payload.SetEvidenceDigest = strings.Repeat("f", 64)
			refreshSnapshot(s, map[string]bool{})
		}},
		{"missing signer proof", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.SignerProofs = nil
			refreshSnapshot(s, v)
		}},
		{"changed run", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.RunID = "stale"
			refreshSnapshot(s, v)
		}},
		{"changed binding", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.BindingDigest = strings.Repeat("f", 64)
			refreshSnapshot(s, v)
		}},
		{"changed chain", func(b *contract.RunBinding, _ *[]ConfiguredNode, _ *ValidatorSnapshotDocument, _ map[string]bool, _ *string) {
			b.ChainID = "other-chain"
		}},
		{"changed genesis", func(b *contract.RunBinding, _ *[]ConfiguredNode, _ *ValidatorSnapshotDocument, _ map[string]bool, _ *string) {
			b.GenesisSHA256 = strings.Repeat("f", 64)
		}},
		{"changed height", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.Height++
			refreshSnapshot(s, v)
		}},
		{"changed set hash", func(_ *contract.RunBinding, _ *[]ConfiguredNode, s *ValidatorSnapshotDocument, v map[string]bool, _ *string) {
			s.Payload.SetHash = strings.Repeat("f", 64)
			refreshSnapshot(s, v)
		}},
		{"artifact not in binding", func(_ *contract.RunBinding, _ *[]ConfiguredNode, _ *ValidatorSnapshotDocument, _ map[string]bool, artifact *string) {
			*artifact = strings.Repeat("f", 64)
		}},
		{"changed configured inventory", func(_ *contract.RunBinding, n *[]ConfiguredNode, _ *ValidatorSnapshotDocument, _ map[string]bool, _ *string) {
			*n = append(*n, ConfiguredNode{NodeID: "unobserved"})
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			b, n, s, v := multiFixture(t, []int64{40, 35, 25}, []string{"v", "w"})
			expectedSetHash := s.Payload.SetHash
			expected := s.Payload.ArtifactDigest
			tc.mutate(&b, &n, &s, v, &expected)
			if _, err := ValidateMultiValidator(b, n, s, 2, b.Heights.FirstRepaired, expectedSetHash, expected, v); err == nil {
				t.Fatal("invalid evidence accepted")
			}
		})
	}
}

func TestValidateMultiValidatorRequiresStrictlyMoreThanTwoThirds(t *testing.T) {
	for _, tc := range []struct {
		name    string
		powers  []int64
		signers []string
	}{{"uneven weights", []int64{40, 35, 25}, []string{"v", "x"}}, {"exactly two thirds", []int64{40, 20, 40}, []string{"v", "w"}}} {
		t.Run(tc.name, func(t *testing.T) {
			b, n, s, v := multiFixture(t, tc.powers, tc.signers)
			if _, err := ValidateMultiValidator(b, n, s, 2, b.Heights.FirstRepaired, s.Payload.SetHash, s.Payload.ArtifactDigest, v); err == nil {
				t.Fatal("power at or below two thirds accepted")
			}
		})
	}
}

func TestMachineEvidenceDecodersAreStrictAndDigestEnvelopeIsNonCircular(t *testing.T) {
	_, _, snapshot, _ := multiFixture(t, []int64{40, 35, 25}, []string{"v", "w"})
	raw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeValidatorSnapshot(bytes.NewReader(raw))
	if err != nil || decoded.EvidenceDigest != snapshot.EvidenceDigest {
		t.Fatalf("valid snapshot decode: %v", err)
	}
	for name, body := range map[string][]byte{"duplicate key": bytes.Replace(raw, []byte(`"run_id":`), []byte(`"run_id":"duplicate","run_id":`), 1), "case alias": bytes.Replace(raw, []byte(`"run_id":`), []byte(`"Run_ID":"alias","run_id":`), 1), "unknown key": bytes.Replace(raw, []byte(`"run_id":`), []byte(`"extra":true,"run_id":`), 1)} {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeValidatorSnapshot(bytes.NewReader(body)); err == nil {
				t.Fatal("invalid evidence accepted")
			}
		})
	}
	proof := LateReplayProof{SchemaVersion: MultiValidatorSchemaVersion, SourceEvidenceDigest: strings.Repeat("e", 64)}
	doc := LateReplayDocument{Payload: proof, EvidenceDigest: LateReplayEvidenceDigest(proof)}
	proofBytes, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeLateReplayProof(bytes.NewReader(proofBytes)); err != nil {
		t.Fatalf("valid proof decode: %v", err)
	}
	if _, err := DecodeLateReplayProof(bytes.NewReader(append(proofBytes, []byte(` {}`)...))); err == nil {
		t.Fatal("trailing JSON accepted")
	}
}

func TestValidateLateReplayBindsLagProofToActiveCommonIdentity(t *testing.T) {
	b, _, active, _ := multiFixture(t, []int64{40, 35, 25}, []string{"v", "w"})
	doc, registry := replayFixture(t, b, active)
	if err := ValidateLateReplay(b, active, doc, 12, "block-12", "app-12", active.Payload.ArtifactDigest, registry); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		mutate func(*LateReplayProof)
	}{
		{"missing lag interval", func(p *LateReplayProof) { p.FromHeight = 12 }},
		{"stale replay origin", func(p *LateReplayProof) { p.FromHeight = b.Heights.FirstRepaired - 1 }},
		{"different block", func(p *LateReplayProof) { p.BlockID = "other-block" }},
		{"different app hash", func(p *LateReplayProof) { p.AppHash = "other-app" }},
		{"different replay mode", func(p *LateReplayProof) { p.ReplayMode = "unverified-mode" }},
		{"stale run", func(p *LateReplayProof) { p.RunID = "another-run" }},
		{"stale binding", func(p *LateReplayProof) { p.BindingDigest = strings.Repeat("f", 64) }},
		{"different chain", func(p *LateReplayProof) { p.ChainID = "another-chain" }},
		{"different genesis", func(p *LateReplayProof) { p.GenesisSHA256 = strings.Repeat("f", 64) }},
		{"different artifact", func(p *LateReplayProof) { p.ArtifactDigest = strings.Repeat("f", 64) }},
		{"changed validator set", func(p *LateReplayProof) { p.ValidatorSetHash = strings.Repeat("f", 64) }},
		{"identity substitution", func(p *LateReplayProof) { p.ValidatorID = "observer" }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			candidate := doc
			tc.mutate(&candidate.Payload)
			candidate.EvidenceDigest = LateReplayEvidenceDigest(candidate.Payload)
			registry[candidate.EvidenceDigest] = true
			if err := ValidateLateReplay(b, active, candidate, 12, "block-12", "app-12", active.Payload.ArtifactDigest, registry); err == nil {
				t.Fatal("stale or substituted replay accepted")
			}
		})
	}
	if err := ValidateLateReplay(b, active, doc, 12, "block-12", "app-12", active.Payload.ArtifactDigest, map[string]bool{}); err == nil {
		t.Fatal("unregistered digest references accepted")
	}
}
