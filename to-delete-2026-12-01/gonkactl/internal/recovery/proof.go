package recovery

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
)

var ErrApprovalInvalid = errors.New("recovery approval is invalid")

// VerifyApproval verifies the immutable payload bytes, not a reserialized JSON
// value. Caller must separately validate payload/approval schemas, trust-store
// membership, host/phase scope, expiry and predecessor order.
func VerifyApproval(payload []byte, signatureHex string, publicKey ed25519.PublicKey) error {
	if len(publicKey) != ed25519.PublicKeySize {
		return ErrApprovalInvalid
	}
	signature, err := hex.DecodeString(signatureHex)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return ErrApprovalInvalid
	}
	sum := sha256.Sum256(payload)
	message := []byte("gonkactl-recovery-approval-v1:\n" + hex.EncodeToString(sum[:]))
	if !ed25519.Verify(publicKey, message, signature) {
		return ErrApprovalInvalid
	}
	return nil
}

func RuntimeQualification(proofStatus string, runtimeSHA256 string) bool {
	return proofStatus == "pass" && len(runtimeSHA256) == 64
}
