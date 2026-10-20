package capture

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"

	cmtcryptoed "github.com/cometbft/cometbft/crypto/ed25519"
	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

func TestSignedProofVerifierBindsSignedSnapshotTripletToManifest(t *testing.T) {
	_, binding, manifest := testAuthorizedAdapter(t, t.TempDir(), "signed-proof")
	now, private := signedVerifierClockAndKey()
	inputContext, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	metadata := func(kind string) contract.SignedMetadata {
		return contract.SignedMetadata{SchemaVersion: contract.Version, Kind: kind, Scope: "capture", KeyID: "archive-test", RunID: binding.RunID, BindingDigest: inputContext, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}
	}
	freeze := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID string `json:"snapshot_id"`
		Checkpoint string `json:"checkpoint"`
		Frozen     bool   `json:"frozen"`
	}{metadata("snapshot_freeze"), manifest.SnapshotID, manifest.Checkpoint, true}, private)
	layout := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID     string   `json:"snapshot_id"`
		Backend        string   `json:"backend"`
		Layout         string   `json:"layout"`
		BackendVersion string   `json:"backend_version"`
		ComponentRoots []string `json:"component_roots"`
	}{metadata("layout_proof"), manifest.SnapshotID, manifest.Backend, manifest.Layout, manifest.BackendVersion, []string{"data"}}, private)
	inventory := signedProofEnvelope(t, struct {
		contract.SignedMetadata
		SnapshotID string                `json:"snapshot_id"`
		Files      []contract.ExportFile `json:"files"`
	}{metadata("inventory_receipt"), manifest.SnapshotID, manifest.Files}, private)
	binding.InputDigests["snapshot_freeze"] = contract.PayloadDigest(proofPayload(t, freeze))
	binding.InputDigests["layout_proof"] = contract.PayloadDigest(proofPayload(t, layout))
	binding.InputDigests["inventory_receipt"] = contract.PayloadDigest(proofPayload(t, inventory))
	verifier := SignedProofVerifier{Roots: []input.TrustRoot{{KeyID: "archive-test", Role: "archive_owner", Scopes: map[string]bool{"capture": true}, PublicKey: private.Public().(ed25519.PublicKey)}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Clock: func() time.Time { return now }}
	got, err := verifier.VerifySnapshotInputs(context.Background(), binding, manifest, freeze, layout, inventory)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Frozen || got.SnapshotID != manifest.SnapshotID || got.InventorySHA256 == "" {
		t.Fatalf("unexpected signed verification: %+v", got)
	}
}

func TestSignedProofVerifierRejectsUnsignedWitnessBeforeAnyQuorumClaim(t *testing.T) {
	_, binding, _ := testAuthorizedAdapter(t, t.TempDir(), "signed-witness")
	now, private := signedVerifierClockAndKey()
	inputContext, err := contract.InputBindingDigest(binding)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(struct {
		contract.SignedMetadata
		SourceIdentity string `json:"source_identity"`
		BlockID        string `json:"block_id"`
		BlockHeight    int64  `json:"block_height"`
		AppHash        string `json:"app_hash"`
		AppHashHeight  int64  `json:"app_hash_height"`
	}{contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "capture_witness", Scope: "capture", KeyID: "witness-a", RunID: binding.RunID, BindingDigest: inputContext, ChainID: binding.ChainID, GenesisSHA256: binding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}, "source-a", binding.BlockID, binding.Heights.Blockstore, binding.AppHash, binding.Heights.App})
	if err != nil {
		t.Fatal(err)
	}
	// The envelope signature is valid, but missing raw Comet bytes make the
	// typed proof ineligible before it can claim a quorum.
	witness := signedProofEnvelope(t, json.RawMessage(payload), private)
	binding.InputDigests["capture_witness"] = contract.PayloadDigest(proofPayload(t, witness))
	verifier := SignedProofVerifier{Roots: []input.TrustRoot{{KeyID: "witness-a", Role: "witness", Scopes: map[string]bool{"capture": true}, PublicKey: private.Public().(ed25519.PublicKey)}}, Revocations: input.RevocationSnapshot{ValidUntil: now.Add(time.Hour), Revoked: map[string]bool{}}, Clock: func() time.Time { return now }}
	if _, err := verifier.VerifyWitness(context.Background(), binding, witness); err == nil {
		t.Fatal("metadata-only witness was accepted")
	}
}

func TestSignedProofVerifierRecomputesQuorumFromRawCometProof(t *testing.T) {
	f := makeSignedWitnessFixture(t)
	verifier := SignedProofVerifier{Roots: []input.TrustRoot{{KeyID: "witness-a", Role: "witness", Scopes: map[string]bool{"capture": true}, PublicKey: f.envelopeKey.Public().(ed25519.PublicKey)}}, Revocations: input.RevocationSnapshot{ValidUntil: f.now.Add(time.Hour), Revoked: map[string]bool{}}, Clock: func() time.Time { return f.now }}

	t.Run("genuine quorum", func(t *testing.T) {
		got, err := verifier.VerifyWitness(context.Background(), f.binding, f.envelope)
		if err != nil {
			t.Fatal(err)
		}
		if got.SignedVotingPower != 30 || got.TotalVotingPower != 40 || len(got.SignerIDs) != 3 || !got.ValidatorSetComplete {
			t.Fatalf("unexpected raw-Comet quorum result: %+v", got)
		}
	})

	t.Run("substituted raw commit", func(t *testing.T) {
		proof := f.proof
		proof.CommitBase64 = base64.StdEncoding.EncodeToString(f.alternateCommit)
		// Keep the signed commit digest pinned to the genuine commit. VerifyWitness
		// must hash the supplied protobuf bytes instead of trusting the envelope.
		if _, err := verifier.VerifyWitness(context.Background(), f.binding, f.envelopeFor(t, proof)); err == nil || !strings.Contains(err.Error(), "seen-commit hash") {
			t.Fatalf("substituted raw commit was not rejected by its pinned hash: %v", err)
		}
	})

	t.Run("declared voting power mismatch", func(t *testing.T) {
		proof := f.proof
		proof.SignedVotingPower = 40
		if _, err := verifier.VerifyWitness(context.Background(), f.binding, f.envelopeFor(t, proof)); err == nil || !strings.Contains(err.Error(), "declared voting power") {
			t.Fatalf("incorrect declared power was accepted or rejected at the wrong check: %v", err)
		}
	})

	t.Run("declared signer identity mismatch", func(t *testing.T) {
		proof := f.proof
		proof.ValidatorSignerIDs = append([]string(nil), f.proof.ValidatorSignerIDs...)
		proof.ValidatorSignerIDs[0] = "not-a-raw-comet-signer"
		if _, err := verifier.VerifyWitness(context.Background(), f.binding, f.envelopeFor(t, proof)); err == nil || !strings.Contains(err.Error(), "signer identities") {
			t.Fatalf("incorrect signer identities were accepted or rejected at the wrong check: %v", err)
		}
	})

	t.Run("same envelope signer cannot supply both witnesses", func(t *testing.T) {
		second := f.proof
		second.SourceIdentity = "independent-source-b"
		if err := verifyWitnesses(verifier, context.Background(), f.binding, [][]byte{f.envelope, f.envelopeFor(t, second)}); err == nil || !strings.Contains(err.Error(), "signer keys") {
			t.Fatalf("two sources signed by one key were accepted or rejected at the wrong check: %v", err)
		}
	})

	t.Run("insufficient raw quorum despite claimed majority", func(t *testing.T) {
		proof := f.proof
		proof.CommitBase64 = base64.StdEncoding.EncodeToString(f.minorityCommit)
		proof.SeenCommitSHA256 = f.minorityCommitHash
		if _, err := verifier.VerifyWitness(context.Background(), f.binding, f.envelopeFor(t, proof)); err == nil || !strings.Contains(err.Error(), "signature/quorum") {
			t.Fatalf("raw two-of-four commit met quorum or failed at wrong check: %v", err)
		}
	})
}

type signedWitnessFixture struct {
	now                time.Time
	envelopeKey        ed25519.PrivateKey
	binding            contract.RunBinding
	proof              signedWitnessProof
	envelope           []byte
	alternateCommit    []byte
	minorityCommit     []byte
	minorityCommitHash string
}

func makeSignedWitnessFixture(t *testing.T) signedWitnessFixture {
	t.Helper()
	const chainID = "signed-witness-comet-0.38.21"
	const height = int64(370)
	const partTotal = uint32(2)
	now, envelopeKey := signedVerifierClockAndKey()
	blockHash := bytes.Repeat([]byte{0x31}, 32)
	partHash := bytes.Repeat([]byte{0x42}, 32)
	blockID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(blockHash), PartSetHeader: tmtypes.PartSetHeader{Total: partTotal, Hash: cmtbytes.HexBytes(partHash)}}
	validators := make([]*tmtypes.Validator, 0, 4)
	privateByAddress := make(map[string]cmtcryptoed.PrivKey, 4)
	for i := 0; i < 4; i++ {
		key := cmtcryptoed.GenPrivKey()
		validator := tmtypes.NewValidator(key.PubKey(), 10)
		validators = append(validators, validator)
		privateByAddress[string(validator.Address)] = key
	}
	set := tmtypes.NewValidatorSet(validators)
	makeCommit := func(signerCount int) *tmtypes.Commit {
		commit := &tmtypes.Commit{Height: height, Round: 0, BlockID: blockID, Signatures: make([]tmtypes.CommitSig, set.Size())}
		for i, validator := range set.Validators {
			if i >= signerCount {
				commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagAbsent}
				continue
			}
			timestamp := time.Unix(1_800_000_000+int64(i), 0).UTC()
			commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagCommit, ValidatorAddress: validator.Address, Timestamp: timestamp}
			sig, err := privateByAddress[string(validator.Address)].Sign(commit.VoteSignBytes(chainID, int32(i)))
			if err != nil {
				t.Fatal(err)
			}
			commit.Signatures[i].Signature = sig
		}
		return commit
	}
	marshalCommit := func(commit *tmtypes.Commit) []byte {
		t.Helper()
		raw, err := proto.Marshal(commit.ToProto())
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	commit := makeCommit(3)
	commitRaw := marshalCommit(commit)
	minority := makeCommit(2)
	minorityRaw := marshalCommit(minority)
	validatorProto, err := set.ToProto()
	if err != nil {
		t.Fatal(err)
	}
	validatorRaw, err := proto.Marshal(validatorProto)
	if err != nil {
		t.Fatal(err)
	}
	inputBinding := contract.RunBinding{
		SchemaVersion: contract.Version, RunID: "signed-witness-run", Scenario: contract.Scenario, Workspace: "/tmp/signed-witness-fixture", OwnershipMarker: "marker",
		ChainID: chainID, GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: height, App: height - 1},
		BlockID: hex.EncodeToString(blockHash), AppHash: strings.Repeat("b", 64), AppHashHeight: height - 1,
		ToolVersion: "test", CatalogVersion: "test", InputDigests: map[string]string{"source": strings.Repeat("c", 64)}, RuntimeIdentities: map[string]string{"binary": strings.Repeat("d", 64)}, Paths: map[string]string{},
	}
	bindingDigest, err := contract.InputBindingDigest(inputBinding)
	if err != nil {
		t.Fatal(err)
	}
	metadata := contract.SignedMetadata{SchemaVersion: contract.Version, Kind: "capture_witness", Scope: "capture", KeyID: "witness-a", RunID: inputBinding.RunID, BindingDigest: bindingDigest, ChainID: chainID, GenesisSHA256: inputBinding.GenesisSHA256, IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour)}
	signerIDs := make([]string, 0, 3)
	for _, signature := range commit.Signatures {
		if signature.BlockIDFlag == tmtypes.BlockIDFlagCommit {
			signerIDs = append(signerIDs, hex.EncodeToString(signature.ValidatorAddress))
		}
	}
	proof := signedWitnessProof{
		SignedMetadata: metadata, SourceIdentity: "independent-source", BlockID: hex.EncodeToString(blockHash), BlockHeight: height,
		AppHash: inputBinding.AppHash, AppHashHeight: height - 1, PartSetHash: hex.EncodeToString(partHash), PartSetTotal: partTotal,
		SeenCommitSHA256: hex.EncodeToString(commit.Hash()), ValidatorSetSHA256: hex.EncodeToString(set.Hash()),
		CommitBase64: base64.StdEncoding.EncodeToString(commitRaw), ValidatorSetBase64: base64.StdEncoding.EncodeToString(validatorRaw),
		ValidatorSignerIDs: signerIDs, SignedVotingPower: 30, TotalVotingPower: 40,
	}
	fixture := signedWitnessFixture{now: now, envelopeKey: envelopeKey, binding: inputBinding, proof: proof, alternateCommit: marshalCommit(makeCommit(1)), minorityCommit: minorityRaw, minorityCommitHash: hex.EncodeToString(minority.Hash())}
	fixture.envelope = fixture.envelopeFor(t, proof)
	fixture.binding.InputDigests["capture_witness"] = contract.PayloadDigest(proofPayload(t, fixture.envelope))
	return fixture
}

func (f signedWitnessFixture) envelopeFor(t *testing.T, proof signedWitnessProof) []byte {
	t.Helper()
	return signedProofEnvelope(t, proof, f.envelopeKey)
}

func signedVerifierClockAndKey() (time.Time, ed25519.PrivateKey) {
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	seed := sha256.Sum256([]byte("ephemeral test-only capture approval key"))
	return now, ed25519.NewKeyFromSeed(seed[:])
}

func signedProofEnvelope(t *testing.T, value any, private ed25519.PrivateKey) []byte {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	document, err := json.Marshal(contract.SignedDocument{Payload: payload, SignatureHex: hex.EncodeToString(ed25519.Sign(private, []byte("gonkactl-recovery-approval-v1:\n"+hex.EncodeToString(sum[:]))))})
	if err != nil {
		t.Fatal(err)
	}
	return document
}

func proofPayload(t *testing.T, raw []byte) []byte {
	t.Helper()
	var document contract.SignedDocument
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	return document.Payload
}
