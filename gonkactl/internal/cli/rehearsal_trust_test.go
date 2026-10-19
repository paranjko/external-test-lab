package cli

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoadRehearsalTrustPolicyUsesExplicitPinnedRootsAndRevocations(t *testing.T) {
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	raw := `{"schema_version":"local-trust/v1","roots":[{"key_id":"catalog-a","role":"catalog","scopes":["epoch-length-live-update"],"public_key_hex":"` + hex.EncodeToString(public) + `"}],"revocations":{"valid_until":"2026-10-20T00:00:00Z","revoked":["old-key"]}}`
	path := writeTrustPolicy(t, raw)
	policy, err := loadRehearsalTrustPolicy(path, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(policy.Roots) != 1 || policy.Roots[0].KeyID != "catalog-a" || policy.Roots[0].Role != "catalog" || !policy.Roots[0].Scopes["epoch-length-live-update"] || len(policy.Roots[0].PublicKey) != ed25519.PublicKeySize {
		t.Fatalf("unexpected pinned roots: %+v", policy.Roots)
	}
	if !policy.Revocations.ValidUntil.Equal(time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)) || !policy.Revocations.Revoked["old-key"] {
		t.Fatalf("unexpected revocation state: %+v", policy.Revocations)
	}
}

func TestLoadRehearsalTrustPolicyRejectsUntrustedMalformedAndExpiredFiles(t *testing.T) {
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key := hex.EncodeToString(public)
	valid := `{"schema_version":"local-trust/v1","roots":[{"key_id":"k","role":"operator","scopes":["capture"],"public_key_hex":"` + key + `"}],"revocations":{"valid_until":"2026-10-20T00:00:00Z","revoked":[]}}`
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name, raw string
	}{
		{"expired revocations", strings.Replace(valid, "2026-10-20", "2026-10-19", 1)},
		{"unknown top field", strings.Replace(valid, `"roots":`, `"embedded_key":"not-authority","roots":`, 1)},
		{"case alias", strings.Replace(valid, `"schema_version":`, `"Schema_Version":`, 1)},
		{"duplicate root id", strings.Replace(valid, `"roots":[`, `"roots":[{"key_id":"k","role":"operator","scopes":["capture"],"public_key_hex":"`+key+`"},`, 1)},
		{"invalid key size", strings.Replace(valid, key, "00", 1)},
		{"duplicate scope", strings.Replace(valid, `["capture"]`, `["capture","capture"]`, 1)},
		{"duplicate json key", strings.Replace(valid, `"schema_version":"local-trust/v1"`, `"schema_version":"local-trust/v1","schema_version":"local-trust/v1"`, 1)},
		{"null revoked list", strings.Replace(valid, `"revoked":[]`, `"revoked":null`, 1)},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if _, err := loadRehearsalTrustPolicy(writeTrustPolicy(t, test.raw), now); err == nil {
				t.Fatal("malformed or expired policy was accepted")
			}
		})
	}
	if _, err := loadRehearsalTrustPolicy(writeTrustPolicy(t, valid), time.Time{}); err == nil {
		t.Fatal("zero implicit clock was accepted")
	}
}

func writeTrustPolicy(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "trust-policy.json")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
