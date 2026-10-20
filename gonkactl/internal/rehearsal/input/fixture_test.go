package input

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func TestDecodeSourceManifestRejectsNullOrAliasedRequiredFields(t *testing.T) {
	manifest := fixtureManifest(t, testBinding(), "blockstore.db", []byte("x"))
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &object); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(map[string]json.RawMessage){
		"null heights": func(value map[string]json.RawMessage) { value["heights"] = json.RawMessage(`null`) },
		"omitted required height": func(value map[string]json.RawMessage) {
			var heights map[string]json.RawMessage
			_ = json.Unmarshal(value["heights"], &heights)
			delete(heights, "first_repaired")
			value["heights"], _ = json.Marshal(heights)
		},
		"case alias": func(value map[string]json.RawMessage) {
			var heights map[string]json.RawMessage
			_ = json.Unmarshal(value["heights"], &heights)
			heights["First_Repaired"] = json.RawMessage(`5`)
			value["heights"], _ = json.Marshal(heights)
		},
	} {
		t.Run(name, func(t *testing.T) {
			copyObject := make(map[string]json.RawMessage, len(object))
			for key, field := range object {
				copyObject[key] = field
			}
			mutate(copyObject)
			raw, err := json.Marshal(copyObject)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeSourceManifest(contract.SignedDocument{Payload: raw}); err == nil {
				t.Fatal("invalid required field accepted")
			}
		})
	}
}

func TestLocalFixtureAdapterValidatesFrozenExport(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	binding := testBinding()
	data := []byte("frozen public chain data")
	if err := os.WriteFile(filepath.Join(root, "blockstore.db"), data, 0600); err != nil {
		t.Fatal(err)
	}
	manifest := fixtureManifest(t, binding, "blockstore.db", data)
	payload := fixturePayload(t, manifest)
	binding.InputDigests["source_manifest"] = contract.PayloadDigest(payload)
	receipt, err := (LocalFixtureAdapter{Root: root, SourcePayload: payload}).Capture(context.Background(), binding, manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := contract.ValidateReceipt(receipt, binding); err != nil {
		t.Fatalf("invalid validation receipt: %v", err)
	}
	if receipt.State != contract.Succeeded || receipt.Operation != "validate_local_fixture_only" || !strings.Contains(receipt.Reason, "no file was transferred") {
		t.Fatalf("receipt overstates fixture adapter behavior: %+v", receipt)
	}
}

func TestLocalFixtureAdapterRejectsUnsafeAndChangedFiles(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*testing.T, string, []byte, contract.ExportFile)
	}{
		{"digest mismatch", func(t *testing.T, root string, _ []byte, _ contract.ExportFile) {
			if err := os.WriteFile(filepath.Join(root, "blockstore.db"), []byte("changed"), 0600); err != nil {
				t.Fatal(err)
			}
		}},
		{"extra file", func(t *testing.T, root string, _ []byte, _ contract.ExportFile) {
			if err := os.WriteFile(filepath.Join(root, "extra.db"), []byte("extra"), 0600); err != nil {
				t.Fatal(err)
			}
		}},
		{"symlink", func(t *testing.T, root string, _ []byte, _ contract.ExportFile) {
			if err := os.Symlink("blockstore.db", filepath.Join(root, "link.db")); err != nil {
				t.Fatal(err)
			}
		}},
		{"hardlink", func(t *testing.T, root string, _ []byte, _ contract.ExportFile) {
			if err := os.Link(filepath.Join(root, "blockstore.db"), filepath.Join(root, "alias.db")); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Chmod(root, 0o700); err != nil {
				t.Fatal(err)
			}
			binding := testBinding()
			data := []byte("frozen public chain data")
			filePath := filepath.Join(root, "blockstore.db")
			if err := os.WriteFile(filePath, data, 0600); err != nil {
				t.Fatal(err)
			}
			manifest := fixtureManifest(t, binding, "blockstore.db", data)
			payload := fixturePayload(t, manifest)
			binding.InputDigests["source_manifest"] = contract.PayloadDigest(payload)
			test.mutate(t, root, data, manifest.Files[0])
			if _, err := (LocalFixtureAdapter{Root: root, SourcePayload: payload}).Capture(context.Background(), binding, manifest); err == nil {
				t.Fatal("unsafe fixture accepted")
			}
		})
	}
}

func TestSourceManifestRejectsTraversalAndSensitivePaths(t *testing.T) {
	binding := testBinding()
	for _, candidate := range []string{"../escape.db", `state\\escape.db`, "config/priv_validator_key.json", "/absolute.db"} {
		manifest := fixtureManifest(t, binding, candidate, []byte("x"))
		if err := ValidateSourceManifest(manifest); err == nil {
			t.Errorf("unsafe path %q accepted", candidate)
		}
	}
}

func fixtureManifest(t *testing.T, binding contract.RunBinding, name string, data []byte) contract.SourceManifest {
	t.Helper()
	digest, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(data)
	consensus := *binding.Heights.Consensus
	return contract.SourceManifest{SignedMetadata: contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "source_manifest", Scope: "capture",
		KeyID: "archive", RunID: binding.RunID, BindingDigest: digest, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256,
		IssuedAt: time.Now().UTC().Add(-time.Minute), ExpiresAt: time.Now().UTC().Add(time.Hour)}, SnapshotID: "snapshot-1", Checkpoint: "checkpoint-1",
		Backend: "fixture", Layout: "test", BackendVersion: "1", Frozen: true,
		Heights: contract.Heights{Blockstore: binding.Heights.Blockstore, App: binding.Heights.App, Consensus: &consensus, FirstRepaired: binding.Heights.FirstRepaired},
		Files:   []contract.ExportFile{{Path: name, SHA256: hex.EncodeToString(hash[:]), Size: int64(len(data))}}, Components: []string{"blockstore"}}
}

func fixturePayload(t *testing.T, manifest contract.SourceManifest) []byte {
	t.Helper()
	payload, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}
