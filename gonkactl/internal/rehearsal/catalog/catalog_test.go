package catalog

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

func TestVerifyCatalogAndRecoveryArtifact(t *testing.T) {
	private, public := keypair()
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	binding := binding()
	consensus := int64(3)
	binding.Heights.Consensus = &consensus
	scenario := Scenario{ID: CatalogScope, Description: "test only", BuildDigests: map[string]string{"core": strings.Repeat("a", 64)}, RuntimeDigests: map[string]string{"standard": strings.Repeat("b", 64)}, Backends: []string{"fixture"}, Layouts: []string{"flat"}, BackendVersions: map[string][]string{"fixture": {"1"}}, Files: []FileRule{{Path: "data/block.db", Required: true, Kind: "file", Component: "blockstore"}}, MigrationKeys: []MigrationKey{{Store: "params", KeyHex: "01", BeforePresent: true, BeforeSHA256: strings.Repeat("c", 64), AfterPresent: true, AfterSHA256: strings.Repeat("d", 64)}}, Heights: binding.Heights, FirstRepairedBlock: 12}
	binding.RuntimeIdentities = map[string]string{"standard": strings.Repeat("b", 64)}
	policy := Policy{Verification: input.VerificationPolicy{Kind: CatalogKind, Scope: CatalogScope, Role: "catalog", Binding: binding, Roots: []input.TrustRoot{{KeyID: "test-only", Role: "catalog", Scopes: map[string]bool{CatalogScope: true}, PublicKey: public}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Now: func() time.Time { return now }}, Scope: CatalogScope}
	catPayload := payload(t, binding, CatalogKind, CatalogScope, "test-only", now, map[string]any{"scenarios": []Scenario{scenario}})
	binding.InputDigests[CatalogKind] = contract.PayloadDigest(catPayload)
	policy.Verification.Binding = binding
	cat, err := VerifyCatalog(sign(private, catPayload), policy)
	if err != nil {
		t.Fatal(err)
	}
	if len(cat.Scenarios) != 1 {
		t.Fatalf("unexpected catalog: %+v", cat)
	}
	artifact := RecoveryArtifact{ScenarioID: scenario.ID, BuildDigests: scenario.BuildDigests, RuntimeDigests: scenario.RuntimeDigests, Backend: "fixture", BackendVersion: "1", Layout: "flat", Files: []ArtifactFile{{Path: "data/block.db", SHA256: strings.Repeat("e", 64), Size: 3, Component: "blockstore"}}, MigrationKeys: scenario.MigrationKeys, Heights: binding.Heights, FirstRepairedBlock: 12}
	artifactPayload := payload(t, binding, ArtifactKind, "stage", "test-only", now, artifact)
	binding.InputDigests[ArtifactKind] = contract.PayloadDigest(artifactPayload)
	_, corePublic := keypairFor("synthetic core key")
	corePrivate, _ := keypairFor("synthetic core key")
	policy.Verification.Roots = append(policy.Verification.Roots, input.TrustRoot{KeyID: "core-test", Role: "core", Scopes: map[string]bool{"stage": true}, PublicKey: corePublic})
	artifactPayload = payload(t, binding, ArtifactKind, "stage", "core-test", now, artifact)
	binding.InputDigests[ArtifactKind] = contract.PayloadDigest(artifactPayload)
	policy.Verification.Roots = policy.Verification.Roots[:1]
	policy.Verification.Roots = append(policy.Verification.Roots, input.TrustRoot{KeyID: "core-test", Role: "core", Scopes: map[string]bool{"stage": true}, PublicKey: corePublic})
	policy.Verification.Kind = ArtifactKind
	policy.Verification.Role = "core"
	policy.Verification.Scope = "stage"
	policy.Verification.Binding = binding
	policy.Scope = "stage"
	verifiedLegacyArtifact, err := VerifyArtifact(sign(corePrivate, artifactPayload), policy, cat)
	if err != nil {
		t.Fatal(err)
	}
	if verifiedLegacyArtifact.RequiredStores != nil || verifiedLegacyArtifact.TopologyPolicy != nil || verifiedLegacyArtifact.BlockPolicy != nil {
		t.Fatal("omitted legacy policy fields were converted into explicit allowlists")
	}
	policy.Scope = "capture"
	if _, err := VerifyArtifact(sign(corePrivate, artifactPayload), policy, cat); err == nil {
		t.Fatal("caller-selected artifact scope accepted")
	}
	policy.Scope = ArtifactScope
	mutatedCatalog := cat
	mutatedCatalog.Scenarios = append([]Scenario(nil), cat.Scenarios...)
	mutatedCatalog.Scenarios[0].FirstRepairedBlock++
	if _, err := VerifyArtifact(sign(corePrivate, artifactPayload), policy, mutatedCatalog); err == nil {
		t.Fatal("modified verified catalog accepted")
	}
	artifact.RuntimeDigests = map[string]string{"standard": strings.Repeat("f", 64)}
	artifactPayload = payload(t, binding, ArtifactKind, "stage", "core-test", now, artifact)
	binding.InputDigests[ArtifactKind] = contract.PayloadDigest(artifactPayload)
	policy.Verification.Binding = binding
	if _, err := VerifyArtifact(sign(corePrivate, artifactPayload), policy, cat); err == nil {
		t.Fatal("artifact runtime mismatch accepted")
	}
}

func TestCatalogStrictAndPinnedTrustRejections(t *testing.T) {
	private, public := keypair()
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	b := binding()
	b.Heights.FirstRepaired = 1
	s := Scenario{ID: CatalogScope, Description: "test", BuildDigests: map[string]string{"core": strings.Repeat("a", 64)}, RuntimeDigests: map[string]string{"run": strings.Repeat("b", 64)}, Backends: []string{"fixture"}, Layouts: []string{"flat"}, BackendVersions: map[string][]string{"fixture": {"1"}}, Files: []FileRule{{Path: "db/file", Required: true, Kind: "file", Component: "block"}}, MigrationKeys: []MigrationKey{}, Heights: b.Heights, FirstRepairedBlock: 1}
	b.RuntimeIdentities = s.RuntimeDigests
	p := Policy{Scope: CatalogScope, Verification: input.VerificationPolicy{Binding: b, Roots: []input.TrustRoot{{KeyID: "id", Role: "catalog", Scopes: map[string]bool{CatalogScope: true}, PublicKey: public}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Now: func() time.Time { return now }}}
	raw := payload(t, b, CatalogKind, CatalogScope, "id", now, map[string]any{"scenarios": []Scenario{s}})
	b.InputDigests[CatalogKind] = contract.PayloadDigest(raw)
	p.Verification.Binding = b
	if _, err := VerifyCatalog(sign(private, raw), p); err != nil {
		t.Fatal(err)
	}
	p.Verification.Role = "operator"
	if _, err := VerifyCatalog(sign(private, raw), p); err == nil {
		t.Fatal("wrong role accepted")
	}
	p.Verification.Role = ""
	p.Scope = "capture"
	if _, err := VerifyCatalog(sign(private, raw), p); err == nil {
		t.Fatal("caller-selected catalog scope accepted")
	}
	if _, err := DecodeEnvelope([]byte(`{"payload":{},"signature_hex":"aa","extra":true}`)); err == nil {
		t.Fatal("unknown envelope field accepted")
	}
}

func TestNestedExactNamesAndMigrationPresence(t *testing.T) {
	raw := []byte(`{"schema_version":"rehearsal/v1","kind":"catalog","scope":"epoch-length-live-update","key_id":"k","run_id":"r","binding_digest":"x","chain_id":"c","genesis_sha256":"x","issued_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-02T00:00:00Z","scenarios":[{"ID":"s"}]}`)
	if err := exactShape(raw, catalogShape()); err == nil {
		t.Fatal("case-folded nested field accepted")
	}
	emptyDigest := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	if err := validateMigration([]MigrationKey{{Store: "s", KeyHex: "01", BeforePresent: true, BeforeSHA256: emptyDigest, AfterPresent: false}}); err != nil {
		t.Fatalf("present empty value versus absent accepted representation rejected: %v", err)
	}
	if err := validateMigration([]MigrationKey{{Store: "s", KeyHex: "01", BeforePresent: false, BeforeSHA256: emptyDigest, AfterPresent: true, AfterSHA256: emptyDigest}}); err == nil {
		t.Fatal("absent value carrying digest accepted")
	}
}

func TestSignedDomainPoliciesPreserveMissingVersusExplicitEmptyAndRejectWidening(t *testing.T) {
	private, public := keypair()
	corePrivate, corePublic := keypairFor("domain policy core key")
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	b := binding()
	consensus := int64(3)
	b.Heights.Consensus = &consensus
	stores := []string{"auth", "params"}
	empty := []PolicyChange{}
	scenario := Scenario{ID: CatalogScope, Description: "policy fixture", BuildDigests: map[string]string{"core": strings.Repeat("a", 64)}, RuntimeDigests: map[string]string{"runtime": strings.Repeat("b", 64)}, Backends: []string{"fixture"}, Layouts: []string{"flat"}, BackendVersions: map[string][]string{"fixture": {"1"}}, Files: []FileRule{{Path: "data.db", Required: true, Kind: "file", Component: "blockstore"}}, MigrationKeys: []MigrationKey{}, RequiredStores: &stores, TopologyPolicy: &DomainPolicy{Changes: append([]PolicyChange{}, empty...)}, BlockPolicy: &DomainPolicy{Changes: append([]PolicyChange{}, empty...)}, Heights: b.Heights, FirstRepairedBlock: b.Heights.FirstRepaired}
	b.RuntimeIdentities = scenario.RuntimeDigests
	policy := Policy{Scope: CatalogScope, Verification: input.VerificationPolicy{Binding: b, Roots: []input.TrustRoot{{KeyID: "catalog", Role: "catalog", Scopes: map[string]bool{CatalogScope: true}, PublicKey: public}, {KeyID: "core", Role: "core", Scopes: map[string]bool{ArtifactScope: true}, PublicKey: corePublic}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Now: func() time.Time { return now }}}
	catPayload := payload(t, b, CatalogKind, CatalogScope, "catalog", now, map[string]any{"scenarios": []Scenario{scenario}})
	b.InputDigests[CatalogKind] = contract.PayloadDigest(catPayload)
	policy.Verification.Binding = b
	verifiedCatalog, err := VerifyCatalog(sign(private, catPayload), policy)
	if err != nil {
		t.Fatal(err)
	}
	artifact := RecoveryArtifact{ScenarioID: scenario.ID, BuildDigests: scenario.BuildDigests, RuntimeDigests: scenario.RuntimeDigests, Backend: "fixture", BackendVersion: "1", Layout: "flat", Files: []ArtifactFile{{Path: "data.db", SHA256: strings.Repeat("c", 64), Size: 10, Component: "blockstore"}}, MigrationKeys: []MigrationKey{}, RequiredStores: &stores, TopologyPolicy: &DomainPolicy{Changes: append([]PolicyChange{}, empty...)}, BlockPolicy: &DomainPolicy{Changes: append([]PolicyChange{}, empty...)}, Heights: b.Heights, FirstRepairedBlock: b.Heights.FirstRepaired}
	verifyArtifact := func(candidate RecoveryArtifact) (RecoveryArtifact, error) {
		raw := payload(t, b, ArtifactKind, ArtifactScope, "core", now, candidate)
		b.InputDigests[ArtifactKind] = contract.PayloadDigest(raw)
		policy.Verification.Binding = b
		policy.Scope = ArtifactScope
		policy.Verification.Kind = ArtifactKind
		policy.Verification.Scope = ArtifactScope
		policy.Verification.Role = "core"
		// InputBindingDigest excludes the document's own digest, so regenerate
		// after setting the signed payload digest and retain the final digest.
		raw = payload(t, b, ArtifactKind, ArtifactScope, "core", now, candidate)
		b.InputDigests[ArtifactKind] = contract.PayloadDigest(raw)
		policy.Verification.Binding = b
		return VerifyArtifact(sign(corePrivate, raw), policy, verifiedCatalog)
	}
	verifiedArtifact, err := verifyArtifact(artifact)
	if err != nil {
		t.Fatal(err)
	}
	if verifiedArtifact.TopologyPolicy == nil || verifiedArtifact.TopologyPolicy.Changes == nil || len(verifiedArtifact.TopologyPolicy.Changes) != 0 || verifiedArtifact.BlockPolicy == nil || verifiedArtifact.BlockPolicy.Changes == nil || verifiedArtifact.RequiredStores == nil || len(*verifiedArtifact.RequiredStores) != 2 {
		t.Fatalf("explicitly empty/signed policies lost: %+v", verifiedArtifact)
	}
	t.Run("artifact widens topology policy", func(t *testing.T) {
		bad := artifact
		bad.TopologyPolicy = &DomainPolicy{Changes: []PolicyChange{{Store: "auth", KeyHex: "01", AfterPresent: true, AfterSHA256: strings.Repeat("d", 64)}}}
		if _, err := verifyArtifact(bad); err == nil {
			t.Fatal("signed artifact widened topology policy")
		}
	})
	t.Run("artifact omits signed block policy", func(t *testing.T) {
		bad := artifact
		bad.BlockPolicy = nil
		if _, err := verifyArtifact(bad); err == nil {
			t.Fatal("omitted artifact policy accepted")
		}
	})
	t.Run("artifact widens required stores", func(t *testing.T) {
		bad := artifact
		more := []string{"auth", "params", "extra"}
		bad.RequiredStores = &more
		if _, err := verifyArtifact(bad); err == nil {
			t.Fatal("artifact widened required store inventory")
		}
	})
	t.Run("signed artifact policy widening is rejected", func(t *testing.T) {
		raw := payload(t, b, ArtifactKind, ArtifactScope, "core", now, artifact)
		b.InputDigests[ArtifactKind] = contract.PayloadDigest(raw)
		policy.Verification.Binding = b
		tampered := strings.Replace(string(raw), `"changes":[]`, `"changes":[{"store":"auth","key_hex":"01","before_present":false,"before_sha256":"","after_present":true,"after_sha256":"`+strings.Repeat("d", 64)+`"}]`, 1)
		b.InputDigests[ArtifactKind] = contract.PayloadDigest([]byte(tampered))
		policy.Verification.Binding = b
		doc := sign(corePrivate, []byte(tampered))
		if _, err := VerifyArtifact(doc, policy, verifiedCatalog); err == nil {
			t.Fatal("tampered signed payload accepted")
		}
	})
}

func TestLegacySignedCatalogRemainsReadableButPoliciesStayMissing(t *testing.T) {
	private, public := keypair()
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	b := binding()
	b.Heights.FirstRepaired = 1
	scenario := Scenario{ID: CatalogScope, Description: "legacy", BuildDigests: map[string]string{"core": strings.Repeat("a", 64)}, RuntimeDigests: map[string]string{"run": strings.Repeat("b", 64)}, Backends: []string{"fixture"}, Layouts: []string{"flat"}, BackendVersions: map[string][]string{"fixture": {"1"}}, Files: []FileRule{{Path: "db/file", Required: true, Kind: "file", Component: "block"}}, MigrationKeys: []MigrationKey{}, Heights: b.Heights, FirstRepairedBlock: 1}
	b.RuntimeIdentities = scenario.RuntimeDigests
	p := Policy{Scope: CatalogScope, Verification: input.VerificationPolicy{Binding: b, Roots: []input.TrustRoot{{KeyID: "cat", Role: "catalog", Scopes: map[string]bool{CatalogScope: true}, PublicKey: public}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Now: func() time.Time { return now }}}
	catBytes := payload(t, b, CatalogKind, CatalogScope, "cat", now, map[string]any{"scenarios": []Scenario{scenario}})
	b.InputDigests[CatalogKind] = contract.PayloadDigest(catBytes)
	p.Verification.Binding = b
	cat, err := VerifyCatalog(sign(private, catBytes), p)
	if err != nil {
		t.Fatalf("legacy catalog no longer parses: %v", err)
	}
	if cat.Scenarios[0].TopologyPolicy != nil || cat.Scenarios[0].BlockPolicy != nil || cat.Scenarios[0].RequiredStores != nil {
		t.Fatal("omitted legacy catalog policies were converted into explicit allowlists")
	}
}

func binding() contract.RunBinding {
	d := strings.Repeat("0", 64)
	return contract.RunBinding{SchemaVersion: contract.Version, RunID: "test-run", Scenario: contract.Scenario, Workspace: "/tmp/rehearsal", OwnershipMarker: "owner", ChainID: "test-chain", GenesisSHA256: d, Heights: contract.Heights{Blockstore: 4, App: 3, FirstRepaired: 12}, BlockID: "block-4", AppHash: "apphash", AppHashHeight: 3, ToolVersion: "test", CatalogVersion: "test", InputDigests: map[string]string{CatalogKind: d, ArtifactKind: d}, RuntimeIdentities: map[string]string{"runtime": "test"}, Paths: map[string]string{}}
}
func keypair() (ed25519.PrivateKey, ed25519.PublicKey) {
	return keypairFor("synthetic catalog test key")
}
func keypairFor(label string) (ed25519.PrivateKey, ed25519.PublicKey) {
	seed := sha256.Sum256([]byte(label))
	priv := ed25519.NewKeyFromSeed(seed[:])
	return priv, priv.Public().(ed25519.PublicKey)
}
func payload(t *testing.T, b contract.RunBinding, kind, scope, key string, now time.Time, body any) []byte {
	t.Helper()
	bd, err := contract.InputBindingDigest(b)
	if err != nil {
		t.Fatal(err)
	}
	meta := map[string]any{"schema_version": contract.Version, "kind": kind, "scope": scope, "key_id": key, "run_id": b.RunID, "binding_digest": bd, "chain_id": b.ChainID, "genesis_sha256": b.GenesisSHA256, "issued_at": now.Add(-time.Minute), "expires_at": now.Add(time.Hour)}
	var m map[string]any
	rawBody, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(rawBody, &m); err != nil {
		t.Fatal(err)
	}
	for k, v := range m {
		meta[k] = v
	}
	raw, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
func sign(priv ed25519.PrivateKey, payload []byte) contract.SignedDocument {
	sum := sha256.Sum256(payload)
	msg := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	return contract.SignedDocument{Payload: json.RawMessage(payload), SignatureHex: hex.EncodeToString(ed25519.Sign(priv, msg))}
}
