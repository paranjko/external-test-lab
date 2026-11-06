package backup

import (
	"bytes"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
)

func TestTask_T014(t *testing.T) {
	state := []byte(`{"height":"10","round":"0","step":1,"block_id":null}`)
	manifest := []byte(`{"node_name":"n","chain_id":"c","genesis_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ml_host":null}`)
	members := []model.Member{{Path: "mnemonics", Dir: true}, {Path: "remote-state", Dir: true}, {Path: "remote-state/tmkms", Dir: true}, {Path: "remote-state/tmkms/secrets", Dir: true}, {Path: "remote-state/tmkms/state", Dir: true}, {Path: "remote-state/inference", Dir: true}, {Path: "remote-state/inference/config", Dir: true}, {Path: "identity.json", Data: []byte(`{}`)}, {Path: "manifest.json", Data: manifest}, {Path: "manifest.sha256", Data: []byte("x")}, {Path: "mnemonics/n-cold.mnemonic", Data: []byte("x")}, {Path: "mnemonics/n-warm.mnemonic", Data: []byte("x")}, {Path: "remote-state/tmkms/state/priv_validator_state.json", Data: state}, {Path: "remote-state/tmkms/tmkms.toml", Data: []byte("x")}, {Path: "remote-state/tmkms/secrets/kms-identity.key", Data: []byte("x")}, {Path: "remote-state/tmkms/secrets/priv_validator_key.softsign", Data: []byte("x")}, {Path: "remote-state/inference/config/node_key.json", Data: []byte("{}")}}
	a, hashA, err := Encode(members)
	if err != nil {
		t.Fatal(err)
	}
	b, hashB, err := Encode(members)
	if err != nil || hashA != hashB || !bytes.Equal(a, b) {
		t.Fatalf("determinism %s %s %v", hashA, hashB, err)
	}
	if _, err := VerifyEncoded(a); err != nil {
		t.Fatalf("strict verify %v", err)
	}
}
