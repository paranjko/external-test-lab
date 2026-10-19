package cli

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	cmtcryptoed "github.com/cometbft/cometbft/crypto/ed25519"
	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

func TestNewRootCaptureWithRealSignedProofEnvelopes(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	workspace := filepath.Join(t.TempDir(), "run")
	exportRoot := filepath.Join(t.TempDir(), "frozen-export")
	inputRoot := t.TempDir()
	if err := os.Mkdir(exportRoot, 0o700); err != nil {
		t.Fatal(err)
	}

	data := []byte("synthetic frozen Comet blockstore export")
	fileHash := sha256.Sum256(data)
	if err := os.WriteFile(filepath.Join(exportRoot, "blockstore.db"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	consensusHeight := int64(369)
	inputDigests := map[string]string{}
	for _, key := range []string{"catalog", "recovery_artifact", "source_manifest", "capture_approval", "snapshot_freeze", "layout_proof", "inventory_receipt", "witness_1", "witness_2", "offline_reader"} {
		inputDigests[key] = repeatedDigest('0')
	}
	runtimeHash := sha256.Sum256([]byte("synthetic runtime identity"))
	binding := contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "real-envelope-capture", Scenario: contract.Scenario,
		Workspace: workspace, OwnershipMarker: "synthetic-owner", ChainID: "synthetic-capture-chain",
		GenesisSHA256: repeatedDigest('a'), Heights: contract.Heights{Blockstore: 370, App: 369, Consensus: &consensusHeight, FirstRepaired: 371},
		BlockID: hex.EncodeToString(bytes.Repeat([]byte{0x31}, 32)), AppHash: repeatedDigest('b'), AppHashHeight: 369,
		ToolVersion: "test", CatalogVersion: "synthetic-catalog-v1", InputDigests: inputDigests,
		RuntimeIdentities: map[string]string{"standard": hex.EncodeToString(runtimeHash[:])},
		Paths:             map[string]string{"source": filepath.Join(workspace, "source"), "export": exportRoot},
	}
	inputContext, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}

	roles := []struct{ id, role, scope string }{
		{"archive", "archive_owner", "capture"},
		{"catalog", "catalog", catalog.CatalogScope},
		{"core", "core", catalog.ArtifactScope},
		{"operator", "operator", "capture"},
		{"witness-a", "witness", "capture"},
		{"witness-b", "witness", "capture"},
		{"reader", "offline_reader", "capture"},
	}
	privateKeys := make(map[string]ed25519.PrivateKey, len(roles))
	publicRoots := make([]struct {
		KeyID        string   `json:"key_id"`
		Role         string   `json:"role"`
		Scopes       []string `json:"scopes"`
		PublicKeyHex string   `json:"public_key_hex"`
	}, 0, len(roles))
	for _, item := range roles {
		seed := sha256.Sum256([]byte("real-envelope-capture/" + item.id))
		private := ed25519.NewKeyFromSeed(seed[:])
		privateKeys[item.id] = private
		publicRoots = append(publicRoots, struct {
			KeyID        string   `json:"key_id"`
			Role         string   `json:"role"`
			Scopes       []string `json:"scopes"`
			PublicKeyHex string   `json:"public_key_hex"`
		}{item.id, item.role, []string{item.scope}, hex.EncodeToString(private.Public().(ed25519.PublicKey))})
	}

	metadata := func(kind, scope, keyID string) contract.SignedMetadata {
		return contract.SignedMetadata{
			SchemaVersion: contract.Version, Kind: kind, Scope: scope, KeyID: keyID,
			RunID: binding.RunID, BindingDigest: inputContext, ChainID: binding.ChainID,
			GenesisSHA256: binding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour),
		}
	}
	sign := func(value any, keyID string) ([]byte, []byte) {
		t.Helper()
		payload, marshalErr := json.Marshal(value)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		sum := sha256.Sum256(payload)
		signature := ed25519.Sign(privateKeys[keyID], []byte("gonkactl-recovery-approval-v1:\n"+hex.EncodeToString(sum[:])))
		envelope, marshalErr := json.Marshal(contract.SignedDocument{Payload: payload, SignatureHex: hex.EncodeToString(signature)})
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		return payload, envelope
	}

	manifest := contract.SourceManifest{
		SignedMetadata: metadata("source_manifest", "capture", "archive"), SnapshotID: "frozen-snapshot-1", Checkpoint: "height-370",
		Backend: "fixture", Layout: "single", BackendVersion: "fixture-v1", Frozen: true, Heights: binding.Heights,
		Files:      []contract.ExportFile{{Path: "blockstore.db", SHA256: hex.EncodeToString(fileHash[:]), Size: int64(len(data))}},
		Components: []string{"blockstore"},
	}
	manifestPayload, manifestEnvelope := sign(manifest, "archive")
	binding.InputDigests["source_manifest"] = contract.PayloadDigest(manifestPayload)

	buildHash := sha256.Sum256([]byte("synthetic recovery build"))
	builds := map[string]string{"core": hex.EncodeToString(buildHash[:])}
	runtimes := map[string]string{"standard": binding.RuntimeIdentities["standard"]}
	scenario := catalog.Scenario{
		ID: catalog.CatalogScope, Description: "synthetic local capture fixture", BuildDigests: builds, RuntimeDigests: runtimes,
		Backends: []string{"fixture"}, Layouts: []string{"single"}, BackendVersions: map[string][]string{"fixture": {"fixture-v1"}},
		Files:         []catalog.FileRule{{Path: "blockstore.db", Required: true, Kind: "file", Component: "blockstore"}},
		MigrationKeys: []catalog.MigrationKey{}, Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired,
	}
	catalogPayload, catalogEnvelope := sign(struct {
		contract.SignedMetadata
		Scenarios []catalog.Scenario `json:"scenarios"`
	}{metadata(catalog.CatalogKind, catalog.CatalogScope, "catalog"), []catalog.Scenario{scenario}}, "catalog")
	binding.InputDigests["catalog"] = contract.PayloadDigest(catalogPayload)
	artifact := catalog.RecoveryArtifact{
		ScenarioID: scenario.ID, BuildDigests: builds, RuntimeDigests: runtimes, Backend: "fixture", BackendVersion: "fixture-v1", Layout: "single",
		Files:         []catalog.ArtifactFile{{Path: "blockstore.db", SHA256: hex.EncodeToString(fileHash[:]), Size: int64(len(data)), Component: "blockstore"}},
		MigrationKeys: []catalog.MigrationKey{}, Heights: binding.Heights, FirstRepairedBlock: binding.Heights.FirstRepaired,
	}
	artifactPayload, artifactEnvelope := sign(struct {
		contract.SignedMetadata
		catalog.RecoveryArtifact
	}{metadata(catalog.ArtifactKind, catalog.ArtifactScope, "core"), artifact}, "core")
	binding.InputDigests["recovery_artifact"] = contract.PayloadDigest(artifactPayload)
	approvalPayload, approvalEnvelope := sign(metadata("approval", "capture", "operator"), "operator")
	binding.InputDigests["capture_approval"] = contract.PayloadDigest(approvalPayload)

	commitRaw, validatorRaw, signerIDs, commitHash, validatorHash := realCaptureQuorum(t, binding.ChainID, 370)
	proofFilePaths := map[string]string{}
	writeProof := func(name string, envelope []byte) {
		t.Helper()
		path := filepath.Join(inputRoot, name+".json")
		if err := os.WriteFile(path, envelope, 0o600); err != nil {
			t.Fatal(err)
		}
		proofFilePaths[name] = path
		binding.InputDigests[name] = contract.PayloadDigest(envelope)
	}
	freezePayload, freezeEnvelope := sign(struct {
		contract.SignedMetadata
		SnapshotID string `json:"snapshot_id"`
		Checkpoint string `json:"checkpoint"`
		Frozen     bool   `json:"frozen"`
	}{metadata("snapshot_freeze", "capture", "archive"), manifest.SnapshotID, manifest.Checkpoint, true}, "archive")
	writeProof("snapshot_freeze", freezeEnvelope)
	_ = freezePayload
	_, layoutEnvelope := sign(struct {
		contract.SignedMetadata
		SnapshotID     string   `json:"snapshot_id"`
		Backend        string   `json:"backend"`
		Layout         string   `json:"layout"`
		BackendVersion string   `json:"backend_version"`
		ComponentRoots []string `json:"component_roots"`
	}{metadata("layout_proof", "capture", "archive"), manifest.SnapshotID, manifest.Backend, manifest.Layout, manifest.BackendVersion, []string{"data"}}, "archive")
	writeProof("layout_proof", layoutEnvelope)
	_, inventoryEnvelope := sign(struct {
		contract.SignedMetadata
		SnapshotID string                `json:"snapshot_id"`
		Files      []contract.ExportFile `json:"files"`
	}{metadata("inventory_receipt", "capture", "archive"), manifest.SnapshotID, manifest.Files}, "archive")
	writeProof("inventory_receipt", inventoryEnvelope)
	for index, keyID := range []string{"witness-a", "witness-b"} {
		_, witnessEnvelope := sign(struct {
			contract.SignedMetadata
			SourceIdentity     string   `json:"source_identity"`
			BlockID            string   `json:"block_id"`
			BlockHeight        int64    `json:"block_height"`
			AppHash            string   `json:"app_hash"`
			AppHashHeight      int64    `json:"app_hash_height"`
			PartSetHash        string   `json:"part_set_hash"`
			PartSetTotal       uint32   `json:"part_set_total"`
			SeenCommitSHA256   string   `json:"seen_commit_sha256"`
			ValidatorSetSHA256 string   `json:"validator_set_sha256"`
			CommitBase64       string   `json:"commit_base64"`
			ValidatorSetBase64 string   `json:"validator_set_base64"`
			ValidatorSignerIDs []string `json:"validator_signer_ids"`
			SignedVotingPower  uint64   `json:"signed_voting_power"`
			TotalVotingPower   uint64   `json:"total_voting_power"`
		}{metadata("capture_witness", "capture", keyID), "independent-source-" + keyID, binding.BlockID, binding.Heights.Blockstore,
			binding.AppHash, binding.Heights.App, hex.EncodeToString(bytes.Repeat([]byte{0x42}, 32)), 2, commitHash, validatorHash,
			base64.StdEncoding.EncodeToString(commitRaw), base64.StdEncoding.EncodeToString(validatorRaw), signerIDs, 30, 40}, keyID)
		writeProof("witness_"+string(rune('1'+index)), witnessEnvelope)
	}
	zero := 0
	_, readerEnvelope := sign(struct {
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
	}{metadata("offline_reader", "capture", "reader"), manifest.SnapshotID, consensusHeight, manifest.Backend, manifest.Layout, manifest.BackendVersion,
		repeatedDigest('c'), repeatedDigest('d'), []string{"fixture-reader", "--verify"}, &zero, now.Format(time.RFC3339)}, "reader")
	writeProof("offline_reader", readerEnvelope)

	if err := contract.ValidateBinding(binding); err != nil {
		t.Fatalf("capture binding invalid: %v", err)
	}
	writeJSON := func(name string, value any) string {
		t.Helper()
		raw, marshalErr := json.Marshal(value)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		path := filepath.Join(inputRoot, name)
		if writeErr := os.WriteFile(path, raw, 0o600); writeErr != nil {
			t.Fatal(writeErr)
		}
		return path
	}
	bindingPath := writeJSON("binding.json", binding)
	manifestPath := writeJSON("source-manifest.json", json.RawMessage(manifestEnvelope))
	catalogPath := writeJSON("catalog.json", json.RawMessage(catalogEnvelope))
	artifactPath := writeJSON("recovery-artifact.json", json.RawMessage(artifactEnvelope))
	approvalPath := writeJSON("approval.json", json.RawMessage(approvalEnvelope))
	proofsPath := writeJSON("capture-evidence.json", struct {
		Freeze        string   `json:"freeze"`
		Layout        string   `json:"layout"`
		Inventory     string   `json:"inventory"`
		Witnesses     []string `json:"witnesses"`
		OfflineReader string   `json:"offline_reader"`
	}{proofFilePaths["snapshot_freeze"], proofFilePaths["layout_proof"], proofFilePaths["inventory_receipt"],
		[]string{proofFilePaths["witness_1"], proofFilePaths["witness_2"]}, proofFilePaths["offline_reader"]})
	trustPath := writeJSON("trust-policy.json", struct {
		SchemaVersion string `json:"schema_version"`
		Roots         any    `json:"roots"`
		Revocations   struct {
			ValidUntil string   `json:"valid_until"`
			Revoked    []string `json:"revoked"`
		} `json:"revocations"`
	}{SchemaVersion: rehearsalTrustSchema, Roots: publicRoots, Revocations: struct {
		ValidUntil string   `json:"valid_until"`
		Revoked    []string `json:"revoked"`
	}{ValidUntil: "2099-01-01T00:00:00Z", Revoked: []string{}}})

	root := NewRoot()
	root.SetArgs([]string{"recover", contract.Scenario, "capture", "--apply", "--run-id", binding.RunID, "--workspace", binding.Workspace,
		"--binding", bindingPath, "--source-manifest", manifestPath, "--catalog", catalogPath, "--recovery-artifact", artifactPath,
		"--capture-approval", approvalPath, "--capture-evidence", proofsPath, "--trust-policy", trustPath})
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&output)
	if err := root.Execute(); err != nil {
		t.Fatalf("NewRoot capture failed: %v\n%s", err, output.String())
	}
	var outcome contract.Outcome
	if err := json.Unmarshal(output.Bytes(), &outcome); err != nil {
		t.Fatalf("decode CLI outcome: %v\n%s", err, output.String())
	}
	if outcome.Status != "succeeded" || outcome.Code != "capture_succeeded" || outcome.Mutation != "owned_workspace" || outcome.Qualification != "not_run" || len(outcome.Receipts) != 1 || outcome.Receipts[0].State != contract.Succeeded {
		t.Fatalf("unexpected real-envelope capture result: %+v", outcome)
	}
	copied, err := os.ReadFile(filepath.Join(binding.Paths["source"], "blockstore.db"))
	if err != nil || !bytes.Equal(copied, data) {
		t.Fatalf("captured frozen bytes mismatch: %v", err)
	}
	loaded, err := session.Load(binding.Workspace, binding.RunID)
	if err != nil || len(loaded.Receipts) != 2 || loaded.Receipts[1].Phase != contract.Capture || loaded.Receipts[1].State != contract.Succeeded {
		t.Fatalf("real proof capture was not persisted: receipts=%+v err=%v", loaded.Receipts, err)
	}
}

func realCaptureQuorum(t *testing.T, chainID string, height int64) ([]byte, []byte, []string, string, string) {
	t.Helper()
	blockHash, partHash := bytes.Repeat([]byte{0x31}, 32), bytes.Repeat([]byte{0x42}, 32)
	blockID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(blockHash), PartSetHeader: tmtypes.PartSetHeader{Total: 2, Hash: cmtbytes.HexBytes(partHash)}}
	validators := make([]*tmtypes.Validator, 0, 4)
	privateByAddress := make(map[string]cmtcryptoed.PrivKey, 4)
	for range 4 {
		key := cmtcryptoed.GenPrivKey()
		validator := tmtypes.NewValidator(key.PubKey(), 10)
		validators = append(validators, validator)
		privateByAddress[string(validator.Address)] = key
	}
	set := tmtypes.NewValidatorSet(validators)
	commit := &tmtypes.Commit{Height: height, Round: 0, BlockID: blockID, Signatures: make([]tmtypes.CommitSig, set.Size())}
	for index := range commit.Signatures {
		commit.Signatures[index] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagAbsent}
	}
	signerIDs := make([]string, 0, 3)
	for index, validator := range set.Validators {
		if index >= 3 {
			commit.Signatures[index] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagAbsent}
			continue
		}
		timestamp := time.Unix(1_800_000_000+int64(index), 0).UTC()
		signature := tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagCommit, ValidatorAddress: validator.Address, Timestamp: timestamp}
		commit.Signatures[index] = signature
		encoded, err := privateByAddress[string(validator.Address)].Sign(commit.VoteSignBytes(chainID, int32(index)))
		if err != nil {
			t.Fatal(err)
		}
		signature.Signature = encoded
		commit.Signatures[index] = signature
		signerIDs = append(signerIDs, hex.EncodeToString(validator.Address))
	}
	commitRaw, err := proto.Marshal(commit.ToProto())
	if err != nil {
		t.Fatal(err)
	}
	validatorProto, err := set.ToProto()
	if err != nil {
		t.Fatal(err)
	}
	validatorRaw, err := proto.Marshal(validatorProto)
	if err != nil {
		t.Fatal(err)
	}
	return commitRaw, validatorRaw, signerIDs, hex.EncodeToString(commit.Hash()), hex.EncodeToString(set.Hash())
}

func repeatedDigest(char byte) string {
	return string(bytes.Repeat([]byte{char}, 64))
}
