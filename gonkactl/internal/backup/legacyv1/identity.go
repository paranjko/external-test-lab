package legacyv1

import (
	"crypto/ed25519"
	"encoding/base64"
)

// VerifySoftsignPublicKey validates both producer encodings: an Ed25519 seed
// or seed followed by its public key. It never normalizes or rewrites bytes.
func VerifySoftsignPublicKey(encoded, expectedPublic string) error {
	key, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || (len(key) != ed25519.SeedSize && len(key) != ed25519.PrivateKeySize) {
		return ErrInvalidArchive
	}
	public := ed25519.NewKeyFromSeed(key[:ed25519.SeedSize]).Public().(ed25519.PublicKey)
	if len(key) == ed25519.PrivateKeySize && !equal(key[ed25519.SeedSize:], public) {
		return ErrInvalidArchive
	}
	expected, err := base64.StdEncoding.Strict().DecodeString(expectedPublic)
	if err != nil || !equal(expected, public) {
		return ErrInvalidArchive
	}
	return nil
}

func equal(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
