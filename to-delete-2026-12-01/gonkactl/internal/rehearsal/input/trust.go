package input

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/recovery"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type TrustRoot struct {
	KeyID     string
	Role      string
	Scopes    map[string]bool
	PublicKey ed25519.PublicKey
}

type RevocationSnapshot struct {
	ValidUntil time.Time
	Revoked    map[string]bool
}

type VerificationPolicy struct {
	Kind        string
	Scope       string
	Role        string
	Binding     contract.RunBinding
	Roots       []TrustRoot
	Revocations RevocationSnapshot
	Now         func() time.Time
}

// VerifyDocument validates exact signed payload bytes against locally pinned
// trust roots. Public keys from the document are never consulted.
func VerifyDocument(document contract.SignedDocument, policy VerificationPolicy) (contract.SignedMetadata, error) {
	return verifyDocument(document, policy, nil)
}

// VerifyTypedDocument requires a caller-owned exact payload schema while
// sharing the signature, trust, expiry and immutable binding checks. The
// callback validates the original bytes; it must not replace the payload.
func VerifyTypedDocument(document contract.SignedDocument, policy VerificationPolicy, validatePayload func([]byte) error) (contract.SignedMetadata, error) {
	if validatePayload == nil {
		return contract.SignedMetadata{}, fmt.Errorf("typed payload validator required")
	}
	return verifyDocument(document, policy, validatePayload)
}

func verifyDocument(document contract.SignedDocument, policy VerificationPolicy, validatePayload func([]byte) error) (contract.SignedMetadata, error) {
	var metadata contract.SignedMetadata
	if err := contract.ValidateBinding(policy.Binding); err != nil {
		return metadata, fmt.Errorf("invalid run binding: %w", err)
	}
	if err := contract.ValidateSchema("binding", policy.Binding); err != nil {
		return metadata, fmt.Errorf("invalid run binding schema: %w", err)
	}
	if len(document.Payload) == 0 || strings.TrimSpace(string(document.Payload)) == "null" {
		return metadata, fmt.Errorf("signed payload is required")
	}
	var fields map[string]json.RawMessage
	if err := Decode(document.Payload, &fields); err != nil {
		return metadata, fmt.Errorf("decode signed metadata: %w", err)
	}
	if fields == nil {
		return metadata, fmt.Errorf("signed payload must be a JSON object")
	}
	if validatePayload != nil {
		for key := range signedMetadataFields {
			value, ok := fields[key]
			if !ok || strings.TrimSpace(string(value)) == "null" {
				return metadata, fmt.Errorf("missing signed metadata field %s", key)
			}
		}
		// A callback receives a copy, so it cannot alter the bytes subsequently verified.
		if err := validatePayload(append([]byte(nil), document.Payload...)); err != nil {
			return metadata, err
		}
		if err := json.Unmarshal(document.Payload, &metadata); err != nil {
			return metadata, err
		}
	} else if policy.Kind != "source_manifest" {
		if err := exactFields(fields, signedMetadataFields, signedMetadataFields); err != nil {
			return metadata, err
		}
		if err := Decode(document.Payload, &metadata); err != nil {
			return metadata, fmt.Errorf("decode metadata-only signed document: %w", err)
		}
	} else {
		if err := exactFields(fields, sourceManifestFields, sourceManifestFields); err != nil {
			return metadata, err
		}
		if err := json.Unmarshal(document.Payload, &metadata); err != nil {
			return metadata, fmt.Errorf("decode signed metadata: %w", err)
		}
	}
	if metadata.SchemaVersion != contract.Version || metadata.Kind != policy.Kind || metadata.Scope != policy.Scope {
		return metadata, fmt.Errorf("signed document kind, version, or scope mismatch")
	}
	if metadata.RunID != policy.Binding.RunID || metadata.ChainID != policy.Binding.ChainID || metadata.GenesisSHA256 != policy.Binding.GenesisSHA256 {
		return metadata, fmt.Errorf("signed document run or chain binding mismatch")
	}
	bindingDigest, err := contract.InputBindingDigest(policy.Binding)
	if err != nil || metadata.BindingDigest != bindingDigest {
		return metadata, fmt.Errorf("signed document binding digest mismatch")
	}
	if policy.Binding.InputDigests[policy.Kind] != contract.PayloadDigest(document.Payload) {
		return metadata, fmt.Errorf("signed payload digest does not match run binding")
	}
	now := time.Now
	if policy.Now != nil {
		now = policy.Now
	}
	current := now().UTC()
	if policy.Revocations.ValidUntil.IsZero() || !current.Before(policy.Revocations.ValidUntil) {
		return metadata, fmt.Errorf("pinned revocation snapshot is absent or expired")
	}
	if metadata.IssuedAt.IsZero() || metadata.ExpiresAt.IsZero() || metadata.IssuedAt.After(current) || !current.Before(metadata.ExpiresAt) || !metadata.ExpiresAt.After(metadata.IssuedAt) {
		return metadata, fmt.Errorf("signed document is not currently valid")
	}
	if policy.Revocations.Revoked[metadata.KeyID] {
		return metadata, fmt.Errorf("signing key is revoked")
	}
	var root *TrustRoot
	for index := range policy.Roots {
		candidate := &policy.Roots[index]
		if candidate.KeyID == metadata.KeyID {
			if root != nil {
				return metadata, fmt.Errorf("duplicate pinned key ID")
			}
			root = candidate
		}
	}
	if root == nil || root.Role != policy.Role || !root.Scopes[policy.Scope] || len(root.PublicKey) != ed25519.PublicKeySize {
		return metadata, fmt.Errorf("no pinned key authorizes this role and scope")
	}
	if document.SignatureHex != strings.ToLower(document.SignatureHex) {
		return metadata, fmt.Errorf("signature must use lowercase hexadecimal")
	}
	if _, err := hex.DecodeString(document.SignatureHex); err != nil {
		return metadata, fmt.Errorf("invalid signature encoding")
	}
	if err := recovery.VerifyApproval(document.Payload, document.SignatureHex, root.PublicKey); err != nil {
		return metadata, err
	}
	return metadata, nil
}

var signedMetadataFields = map[string]bool{
	"schema_version": true, "kind": true, "scope": true, "key_id": true, "run_id": true,
	"binding_digest": true, "chain_id": true, "genesis_sha256": true, "issued_at": true, "expires_at": true,
}

var sourceManifestFields = map[string]bool{
	"schema_version": true, "kind": true, "scope": true, "key_id": true, "run_id": true,
	"binding_digest": true, "chain_id": true, "genesis_sha256": true, "issued_at": true, "expires_at": true,
	"snapshot_id": true, "checkpoint": true, "backend": true, "layout": true, "backend_version": true,
	"frozen": true, "heights": true, "files": true, "components": true,
}

func exactFields(fields map[string]json.RawMessage, allowed, required map[string]bool) error {
	for key := range fields {
		if !allowed[key] {
			return fmt.Errorf("unsupported or mis-cased JSON field %q", key)
		}
	}
	for key := range required {
		if _, ok := fields[key]; !ok {
			return fmt.Errorf("required JSON field %q is missing", key)
		}
	}
	return nil
}
