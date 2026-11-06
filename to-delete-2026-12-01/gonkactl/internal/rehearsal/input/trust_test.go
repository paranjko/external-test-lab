package input

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestVerifyDocumentUsesExactPayloadAndPinnedScope(t *testing.T) {
	private, public := testKey()
	binding := testBinding()
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	policy := VerificationPolicy{Kind: "recovery_artifact", Scope: "capture", Role: "archive", Binding: binding,
		Roots:       []TrustRoot{{KeyID: "root-a", Role: "archive", Scopes: map[string]bool{"capture": true}, PublicKey: public}},
		Revocations: RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Now: func() time.Time { return now }}
	payload := signedMetadata(t, binding, "recovery_artifact", "root-a", now)
	binding.InputDigests["recovery_artifact"] = contract.PayloadDigest(payload)
	policy.Binding = binding
	document := signDocument(private, payload)
	if _, err := VerifyDocument(document, policy); err != nil {
		t.Fatalf("valid signed payload rejected: %v", err)
	}

	mutated := append([]byte(nil), payload...)
	mutated = []byte(strings.Replace(string(mutated), `"scope":"capture"`, `"scope":"stage"`, 1))
	document.Payload = mutated
	if _, err := VerifyDocument(document, policy); err == nil {
		t.Fatal("mutated exact payload accepted")
	}

	document = signDocument(private, payload)
	policy.Scope = "stage"
	if _, err := VerifyDocument(document, policy); err == nil {
		t.Fatal("signature for capture scope authorized stage")
	}
	policy.Scope = "capture"
	policy.Role = "core"
	if _, err := VerifyDocument(document, policy); err == nil {
		t.Fatal("archive key authorized core role")
	}
}

func TestVerifyDocumentRejectsExpiryRevocationAndDuplicateJSON(t *testing.T) {
	private, public := testKey()
	binding := testBinding()
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	policy := VerificationPolicy{Kind: "recovery_artifact", Scope: "capture", Role: "archive", Binding: binding,
		Roots:       []TrustRoot{{KeyID: "root-a", Role: "archive", Scopes: map[string]bool{"capture": true}, PublicKey: public}},
		Revocations: RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Now: func() time.Time { return now }}
	payload := signedMetadata(t, binding, "recovery_artifact", "root-a", now)
	binding.InputDigests["recovery_artifact"] = contract.PayloadDigest(payload)
	policy.Binding = binding
	doc := signDocument(private, payload)
	var expiredMetadata contract.SignedMetadata
	if err := json.Unmarshal(payload, &expiredMetadata); err != nil {
		t.Fatal(err)
	}
	expiredMetadata.ExpiresAt = now.Add(-time.Second)
	expiredPayload, err := json.Marshal(expiredMetadata)
	if err != nil {
		t.Fatal(err)
	}
	policy.Binding.InputDigests["recovery_artifact"] = contract.PayloadDigest(expiredPayload)
	if _, err := VerifyDocument(signDocument(private, expiredPayload), policy); err == nil {
		t.Fatal("expired approval accepted")
	}
	policy.Binding.InputDigests["recovery_artifact"] = contract.PayloadDigest(payload)
	policy.Revocations.ValidUntil = now
	if _, err := VerifyDocument(doc, policy); err == nil {
		t.Fatal("expired revocation snapshot accepted")
	}
	policy.Revocations.ValidUntil = now.Add(time.Hour)
	policy.Revocations.Revoked["root-a"] = true
	if _, err := VerifyDocument(doc, policy); err == nil {
		t.Fatal("revoked key accepted")
	}
	if err := Decode([]byte(`{"a":{"b":1,"b":2}}`), new(map[string]any)); err == nil {
		t.Fatal("nested duplicate key accepted")
	}
	aliased := append([]byte(nil), payload[:len(payload)-1]...)
	aliased = append(aliased, []byte(`,"Kind":"recovery_artifact"}`)...)
	if _, err := VerifyDocument(signDocument(private, aliased), policy); err == nil {
		t.Fatal("case-aliased signed metadata key accepted")
	}
	unknown := append([]byte(nil), payload[:len(payload)-1]...)
	unknown = append(unknown, []byte(`,"public_key":"attacker"}`)...)
	policy.Revocations.Revoked = map[string]bool{}
	if _, err := VerifyDocument(signDocument(private, unknown), policy); err == nil {
		t.Fatal("unsupported metadata-only field accepted")
	}
}

func testKey() (ed25519.PrivateKey, ed25519.PublicKey) {
	seed := sha256.Sum256([]byte("rehearsal test root"))
	private := ed25519.NewKeyFromSeed(seed[:])
	return private, private.Public().(ed25519.PublicKey)
}

func testBinding() contract.RunBinding {
	consensus := int64(3)
	return contract.RunBinding{SchemaVersion: contract.Version, RunID: "run1", Scenario: contract.Scenario,
		Workspace: "/tmp/rehearsal", OwnershipMarker: "owner1", ChainID: "chain-test",
		GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 4, App: 3, Consensus: &consensus, FirstRepaired: 5},
		BlockID: "block-4", AppHash: "hash-3", AppHashHeight: 3, ToolVersion: "test", CatalogVersion: "test",
		InputDigests: map[string]string{"source": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"runtime": "sha256:test"}, Paths: map[string]string{}}
}

func signedMetadata(t *testing.T, binding contract.RunBinding, kind, keyID string, now time.Time) []byte {
	t.Helper()
	digest, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	metadata := contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: "capture", KeyID: keyID,
		RunID: binding.RunID, BindingDigest: digest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256,
		IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Minute)}
	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func signDocument(private ed25519.PrivateKey, payload []byte) contract.SignedDocument {
	sum := sha256.Sum256(payload)
	message := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	return contract.SignedDocument{Payload: json.RawMessage(payload), SignatureHex: hex.EncodeToString(ed25519.Sign(private, message))}
}
