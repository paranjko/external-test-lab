package legacyv1

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
)

func TestTask_T012(t *testing.T) {
	a := model.SigningState{Height: "9007199254740993", Round: "0002", Step: 1, BlockID: &model.BlockID{Hash: "a", PartsTotal: 1, PartsHash: "p"}}
	b := model.SigningState{Height: "9007199254740992", Round: "2", Step: 1, BlockID: a.BlockID}
	if got, err := CompareHRS(a, b); err != nil || got <= 0 {
		t.Fatalf("exact HRS: %d %v", got, err)
	}
	c := a
	c.BlockID = &model.BlockID{Hash: "b", PartsTotal: 1, PartsHash: "p"}
	if _, err := CompareHRS(a, c); !errors.Is(err, ErrConflictingBlockID) {
		t.Fatalf("block conflict: %v", err)
	}
	if _, err := CompareHRS(model.SigningState{Height: "-1"}, a); !errors.Is(err, ErrInvalidSigningState) {
		t.Fatalf("invalid state: %v", err)
	}
	raw := []byte(`{"app_name":"old","app_hash":false,"initial_height":1,"consensus":{"params":{"b":2,"a":1}},"z":"ok"}`)
	canonical, digest, err := CanonicalGenesis(raw)
	if err != nil || string(canonical) != "{\n  \"app_hash\": \"\",\n  \"consensus_params\": {\n    \"a\": 1,\n    \"b\": 2\n  },\n  \"initial_height\": \"1\",\n  \"z\": \"ok\"\n}\n" {
		t.Fatalf("canonical = %q, %v", canonical, err)
	}
	if digest == RawBootstrapDigest(raw) {
		t.Fatal("canonical and raw digests conflated")
	}
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	if err := VerifySoftsignPublicKey(base64.StdEncoding.EncodeToString(append(seed, pub...)), base64.StdEncoding.EncodeToString(pub)); err != nil {
		t.Fatalf("softsign64 = %v", err)
	}
	if err := VerifySoftsignPublicKey(base64.StdEncoding.EncodeToString(seed), base64.StdEncoding.EncodeToString(pub)); err != nil {
		t.Fatalf("softsign32 = %v", err)
	}
}
