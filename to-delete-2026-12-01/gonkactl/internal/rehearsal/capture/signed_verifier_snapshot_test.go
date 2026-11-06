package capture

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

func TestSignedProofVerifierRejectsTamperedSnapshotEnvelope(t *testing.T) {
	verifier, binding, manifest, freeze, layout, inventory, _ := signedSnapshotFixture(t)
	freeze[len(freeze)-2] ^= 1
	if _, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory); err == nil {
		t.Fatal("tampered freeze envelope was accepted")
	}
}

func TestSignedProofVerifierRejectsLayoutAndInventoryMismatch(t *testing.T) {
	t.Run("empty component roots", func(t *testing.T) {
		verifier, binding, manifest, freeze, _, inventory, sign := signedSnapshotFixture(t)
		layout := signedProofEnvelope(t, struct {
			contract.SignedMetadata
			SnapshotID     string   `json:"snapshot_id"`
			Backend        string   `json:"backend"`
			Layout         string   `json:"layout"`
			BackendVersion string   `json:"backend_version"`
			ComponentRoots []string `json:"component_roots"`
		}{sign("layout_proof"), manifest.SnapshotID, manifest.Backend, manifest.Layout, manifest.BackendVersion, nil}, signedSnapshotPrivate(t))
		binding.InputDigests["layout_proof"] = contract.PayloadDigest(proofPayload(t, layout))
		if _, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory); err == nil {
			t.Fatal("layout with no component roots was accepted")
		}
	})
	t.Run("layout", func(t *testing.T) {
		verifier, binding, manifest, freeze, _, inventory, sign := signedSnapshotFixture(t)
		layout := signedProofEnvelope(t, struct {
			contract.SignedMetadata
			SnapshotID     string   `json:"snapshot_id"`
			Backend        string   `json:"backend"`
			Layout         string   `json:"layout"`
			BackendVersion string   `json:"backend_version"`
			ComponentRoots []string `json:"component_roots"`
		}{sign("layout_proof"), manifest.SnapshotID, manifest.Backend, "different-layout", manifest.BackendVersion, []string{"data"}}, signedSnapshotPrivate(t))
		binding.InputDigests["layout_proof"] = contract.PayloadDigest(proofPayload(t, layout))
		if _, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory); err == nil {
			t.Fatal("layout mismatch was accepted")
		}
	})
	t.Run("inventory", func(t *testing.T) {
		verifier, binding, manifest, freeze, layout, _, sign := signedSnapshotFixture(t)
		inventory := signedProofEnvelope(t, struct {
			contract.SignedMetadata
			SnapshotID string                `json:"snapshot_id"`
			Files      []contract.ExportFile `json:"files"`
		}{sign("inventory_receipt"), manifest.SnapshotID, []contract.ExportFile{}}, signedSnapshotPrivate(t))
		binding.InputDigests["inventory_receipt"] = contract.PayloadDigest(proofPayload(t, inventory))
		if _, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory); err == nil {
			t.Fatal("inventory mismatch was accepted")
		}
	})
}

func TestSignedProofVerifierRejectsExpiredAndRevokedSnapshotSigner(t *testing.T) {
	t.Run("expired", func(t *testing.T) {
		verifier, binding, manifest, freeze, layout, inventory, _ := signedSnapshotFixture(t)
		verifier.Clock = func() time.Time { return signedSnapshotNow().Add(2 * time.Hour) }
		verifier.Revocations.ValidUntil = signedSnapshotNow().Add(3 * time.Hour)
		if _, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory); err == nil {
			t.Fatal("expired snapshot proof was accepted")
		}
	})
	t.Run("revoked", func(t *testing.T) {
		verifier, binding, manifest, freeze, layout, inventory, _ := signedSnapshotFixture(t)
		verifier.Revocations.Revoked["archive-test"] = true
		if _, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory); err == nil {
			t.Fatal("proof from revoked signer was accepted")
		}
	})
}

func TestSignedProofVerifierRejectsWrongOfflineReaderBindingMetadata(t *testing.T) {
	verifier, binding, _, _, _, _, sign := signedSnapshotFixture(t)
	wrong := sign("offline_reader")
	wrong.BindingDigest = "wrong-binding"
	code := 0
	raw := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID         string   `json:"snapshot_id"`
		ConsensusHeight    int64    `json:"consensus_height"`
		Backend            string   `json:"backend"`
		Layout             string   `json:"layout"`
		BackendVersion     string   `json:"backend_version"`
		ReaderSHA256       string   `json:"reader_sha256"`
		ReaderOutputSHA256 string   `json:"reader_output_sha256"`
		Command            []string `json:"command"`
		ExitCode           *int     `json:"exit_code"`
		ObservedUTC        string   `json:"observed_utc"`
	}{wrong, "snapshot", 5, "fixture", "single", "v1", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", []string{"reader"}, &code, signedSnapshotNow().Format(time.RFC3339)}, signedSnapshotPrivate(t))
	binding.InputDigests["offline_reader"] = contract.PayloadDigest(proofPayload(t, raw))
	if _, err := verifier.VerifyOfflineReader(context.Background(), binding, raw); err == nil {
		t.Fatal("offline-reader proof with wrong binding metadata was accepted")
	}
}

func signedSnapshotFixture(t *testing.T) (SignedProofVerifier, contract.RunBinding, contract.SourceManifest, []byte, []byte, []byte, func(string) contract.SignedMetadata) {
	t.Helper()
	_, binding, manifest := testAuthorizedAdapter(t, t.TempDir(), "snapshot-triplet")
	now := signedSnapshotNow()
	private := signedSnapshotPrivate(t)
	bindingDigest, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	sign := func(kind string) contract.SignedMetadata {
		return contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: "capture", KeyID: "archive-test", RunID: binding.RunID, BindingDigest: bindingDigest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}
	}
	freeze := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID string `json:"snapshot_id"`
		Checkpoint string `json:"checkpoint"`
		Frozen     bool   `json:"frozen"`
	}{sign("snapshot_freeze"), manifest.SnapshotID, manifest.Checkpoint, true}, private)
	layout := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID     string   `json:"snapshot_id"`
		Backend        string   `json:"backend"`
		Layout         string   `json:"layout"`
		BackendVersion string   `json:"backend_version"`
		ComponentRoots []string `json:"component_roots"`
	}{sign("layout_proof"), manifest.SnapshotID, manifest.Backend, manifest.Layout, manifest.BackendVersion, []string{"data"}}, private)
	inventory := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID string                `json:"snapshot_id"`
		Files      []contract.ExportFile `json:"files"`
	}{sign("inventory_receipt"), manifest.SnapshotID, manifest.Files}, private)
	binding.InputDigests["snapshot_freeze"] = contract.PayloadDigest(proofPayload(t, freeze))
	binding.InputDigests["layout_proof"] = contract.PayloadDigest(proofPayload(t, layout))
	binding.InputDigests["inventory_receipt"] = contract.PayloadDigest(proofPayload(t, inventory))
	verifier := SignedProofVerifier{Roots: []input.TrustRoot{{KeyID: "archive-test", Role: "archive_owner", Scopes: map[string]bool{"capture": true}, PublicKey: private.Public().(ed25519.PublicKey)}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Clock: func() time.Time { return now }}
	return verifier, binding, manifest, freeze, layout, inventory, sign
}

func signedSnapshotNow() time.Time {
	return time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
}

func signedSnapshotPrivate(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, key := signedVerifierClockAndKey()
	return key
}
