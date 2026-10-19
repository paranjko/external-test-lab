package cli

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

const rehearsalTrustSchema = "local-trust/v1"

// RehearsalTrustPolicy is supplied explicitly by the local operator. It is
// deliberately not loaded from, or inferred from, any signed rehearsal input.
type RehearsalTrustPolicy struct {
	Roots       []input.TrustRoot
	Revocations input.RevocationSnapshot
}

type trustPolicyWire struct {
	SchemaVersion string          `json:"schema_version"`
	Roots         []trustRootWire `json:"roots"`
	Revocations   revocationWire  `json:"revocations"`
}

type trustRootWire struct {
	KeyID        string   `json:"key_id"`
	Role         string   `json:"role"`
	Scopes       []string `json:"scopes"`
	PublicKeyHex string   `json:"public_key_hex"`
}

type revocationWire struct {
	ValidUntil string   `json:"valid_until"`
	Revoked    []string `json:"revoked"`
}

// loadRehearsalTrustPolicy reads an operator-selected local policy. Callers
// must pass an explicit current time; an absent/expired revocation snapshot
// never degrades to an empty or implicitly trusted policy.
func loadRehearsalTrustPolicy(path string, now time.Time) (RehearsalTrustPolicy, error) {
	var out RehearsalTrustPolicy
	if now.IsZero() {
		return out, errors.New("explicit trust-policy clock is required")
	}
	raw, err := readLocalJSON(path)
	if err != nil {
		return out, fmt.Errorf("read local rehearsal trust policy: %w", err)
	}
	if len(raw) == 0 || len(raw) > 1<<20 {
		return out, errors.New("local rehearsal trust policy is empty or exceeds 1 MiB")
	}
	if err := exactTrustObject(raw, []string{"schema_version", "roots", "revocations"}); err != nil {
		return out, fmt.Errorf("decode local rehearsal trust policy: %w", err)
	}
	var wire trustPolicyWire
	if err := contract.DecodeStrict(raw, &wire); err != nil {
		return out, fmt.Errorf("decode local rehearsal trust policy: %w", err)
	}
	if wire.SchemaVersion != rehearsalTrustSchema || len(wire.Roots) == 0 {
		return out, errors.New("local rehearsal trust policy has unsupported schema or no pinned roots")
	}
	if err := exactTrustObject(fieldRaw(raw, "revocations"), []string{"valid_until", "revoked"}); err != nil {
		return out, fmt.Errorf("invalid revocation snapshot: %w", err)
	}
	var rootObjects []json.RawMessage
	if err := json.Unmarshal(fieldRaw(raw, "roots"), &rootObjects); err != nil || rootObjects == nil || len(rootObjects) != len(wire.Roots) {
		return out, errors.New("trust roots must be a non-null array")
	}
	rootIDs := make(map[string]bool, len(wire.Roots))
	for index, root := range wire.Roots {
		if err := exactTrustObject(rootObjects[index], []string{"key_id", "role", "scopes", "public_key_hex"}); err != nil {
			return out, fmt.Errorf("invalid trust root %d: %w", index, err)
		}
		if !trustToken(root.KeyID) || !trustToken(root.Role) || len(root.Scopes) == 0 || rootIDs[root.KeyID] {
			return out, fmt.Errorf("trust root %d has invalid or duplicate key id, role, or scopes", index)
		}
		rootIDs[root.KeyID] = true
		pub, err := hex.DecodeString(root.PublicKeyHex)
		if err != nil || len(pub) != ed25519.PublicKeySize || strings.ToLower(root.PublicKeyHex) != root.PublicKeyHex {
			return out, fmt.Errorf("trust root %q public_key_hex must be lowercase Ed25519 public key hex", root.KeyID)
		}
		scopes := make(map[string]bool, len(root.Scopes))
		for _, scope := range root.Scopes {
			if !trustToken(scope) || scopes[scope] {
				return out, fmt.Errorf("trust root %q has invalid or duplicate scope", root.KeyID)
			}
			scopes[scope] = true
		}
		out.Roots = append(out.Roots, input.TrustRoot{KeyID: root.KeyID, Role: root.Role, Scopes: scopes, PublicKey: ed25519.PublicKey(pub)})
	}
	validUntil, err := time.Parse(time.RFC3339, wire.Revocations.ValidUntil)
	if err != nil || !now.UTC().Before(validUntil.UTC()) {
		return RehearsalTrustPolicy{}, errors.New("pinned revocation snapshot is missing, malformed, or expired")
	}
	var revokedRaw []string
	if err := json.Unmarshal(fieldRaw(fieldRaw(raw, "revocations"), "revoked"), &revokedRaw); err != nil || revokedRaw == nil {
		return RehearsalTrustPolicy{}, errors.New("revocation list must be a non-null array")
	}
	revoked := make(map[string]bool, len(wire.Revocations.Revoked))
	for _, keyID := range wire.Revocations.Revoked {
		if !trustToken(keyID) || revoked[keyID] {
			return RehearsalTrustPolicy{}, errors.New("revocation list contains invalid or duplicate key id")
		}
		revoked[keyID] = true
	}
	out.Revocations = input.RevocationSnapshot{ValidUntil: validUntil.UTC(), Revoked: revoked}
	return out, nil
}

func exactTrustObject(raw []byte, required []string) error {
	var fields map[string]json.RawMessage
	if err := contract.DecodeStrict(raw, &fields); err != nil {
		return err
	}
	if fields == nil || len(fields) != len(required) {
		return errors.New("object has missing or unsupported fields")
	}
	allowed := make(map[string]bool, len(required))
	for _, key := range required {
		allowed[key] = true
	}
	for key, value := range fields {
		if !allowed[key] || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return fmt.Errorf("unsupported field or null value %q", key)
		}
	}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return fmt.Errorf("required field %q is missing", key)
		}
	}
	return nil
}

func fieldRaw(raw []byte, name string) []byte {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return nil
	}
	return fields[name]
}

func trustToken(value string) bool {
	if value == "" || strings.TrimSpace(value) != value {
		return false
	}
	for _, r := range value {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.') {
			return false
		}
	}
	return true
}
