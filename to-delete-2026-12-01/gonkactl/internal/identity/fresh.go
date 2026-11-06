package identity

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
)

// FreshStableKeys are the non-account roots which must survive replacement of
// chain generations. Mnemonic-backed account roots are intentionally produced
// only by the pinned account adapter, never by a guessed Go derivation path.
type FreshStableKeys struct {
	ConsensusPrivate string
	ConsensusPublic  string
	NodePrivate      string
	NodeID           string
}

func GenerateFreshStableKeys() (FreshStableKeys, error) {
	consensusPub, consensusPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return FreshStableKeys{}, err
	}
	nodePub, nodePriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return FreshStableKeys{}, err
	}
	sum := sha256.Sum256(nodePub)
	return FreshStableKeys{ConsensusPrivate: base64.StdEncoding.EncodeToString(consensusPriv), ConsensusPublic: base64.StdEncoding.EncodeToString(consensusPub), NodePrivate: base64.StdEncoding.EncodeToString(nodePriv), NodeID: hex.EncodeToString(sum[:20])}, nil
}

func ValidateFreshStableKeys(keys FreshStableKeys) error {
	consensus, err := base64.StdEncoding.Strict().DecodeString(keys.ConsensusPrivate)
	if err != nil || len(consensus) != ed25519.PrivateKeySize {
		return errors.New("invalid consensus key")
	}
	if base64.StdEncoding.EncodeToString(consensus[ed25519.SeedSize:]) != keys.ConsensusPublic {
		return errors.New("consensus public key mismatch")
	}
	node, err := base64.StdEncoding.Strict().DecodeString(keys.NodePrivate)
	if err != nil || len(node) != ed25519.PrivateKeySize {
		return errors.New("invalid node key")
	}
	sum := sha256.Sum256(node[ed25519.SeedSize:])
	if hex.EncodeToString(sum[:20]) != keys.NodeID {
		return errors.New("node identity mismatch")
	}
	return nil
}
