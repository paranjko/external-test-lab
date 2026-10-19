//go:build linux

package session

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	cmtcryptoed "github.com/cometbft/cometbft/crypto/ed25519"
	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
)

func TestVerifyFreshProducerEvidencePinsBothIndependentRealCometRuns(t *testing.T) {
	f := newProducerVerifyFixture(t)
	result, err := VerifyFresh(context.Background(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now)
	if err != nil || result.Verdict != contract.Pass || result.Qualification != "evidence_verified" || !contract.IsDigest(result.ProducerEvidenceDigest) {
		t.Fatalf("producer-gated fresh verification result=%+v err=%v", result, err)
	}
	_, _, _, receipts, err := lifecycle.ReadStoredSnapshot(f.main.Workspace)
	if err != nil {
		t.Fatal(err)
	}
	verify, ok := successfulPhase(receipts, contract.Verify)
	if !ok || verify.EvidenceDigests[freshResultKey] != mustFreshDigest(t, result) {
		t.Fatal("Verify receipt did not pin producer evidence in fresh result")
	}
	firstBytes, err := os.ReadFile(filepath.Join(f.main.Workspace, "lifecycle.json"))
	if err != nil {
		t.Fatal(err)
	}
	repeat, err := VerifyFresh(context.Background(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now)
	if err != nil || repeat.ProducerEvidenceDigest != result.ProducerEvidenceDigest {
		t.Fatalf("repeat verification=%+v err=%v", repeat, err)
	}
	secondBytes, err := os.ReadFile(filepath.Join(f.main.Workspace, "lifecycle.json"))
	if err != nil || !bytes.Equal(firstBytes, secondBytes) {
		t.Fatalf("repeat verification changed journal: %v", err)
	}
	blockPath := filepath.Join(f.main.Workspace, "evidence", "block-h.bin")
	blockRaw, err := os.ReadFile(blockPath)
	if err != nil {
		t.Fatal(err)
	}
	blockRaw[len(blockRaw)-1] ^= 1
	write0600(t, blockPath, blockRaw)
	if _, err := VerifyFresh(context.Background(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now); err == nil {
		t.Fatal("post-success producer substitution was accepted")
	}
	thirdBytes, err := os.ReadFile(filepath.Join(f.main.Workspace, "lifecycle.json"))
	if err != nil || !bytes.Equal(secondBytes, thirdBytes) {
		t.Fatalf("post-success rejection changed journal: %v", err)
	}
	report, err := evidence.Render(result)
	if err != nil || !bytes.Contains(report.JSON, []byte(result.ProducerEvidenceDigest)) {
		t.Fatal("report omitted pinned producer digest")
	}
}

func TestVerifyFreshProducerEvidenceFailsClosedForMissingSubstitutionAndWrongRun(t *testing.T) {
	t.Run("missing", func(t *testing.T) {
		f := newProducerVerifyFixture(t)
		if err := os.Remove(filepath.Join(f.main.Workspace, "evidence", "producer-manifest.json")); err != nil {
			t.Fatal(err)
		}
		assertFreshProducerRejected(t, f)
	})
	t.Run("substitution", func(t *testing.T) {
		f := newProducerVerifyFixture(t)
		path := filepath.Join(f.main.Workspace, "evidence", "block-h.bin")
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		raw[len(raw)-1] ^= 1
		write0600(t, path, raw)
		assertFreshProducerRejected(t, f)
	})
	t.Run("wrong-run", func(t *testing.T) {
		f := newProducerVerifyFixture(t)
		var want coregate.ProducerExpectation
		raw, err := os.ReadFile(filepath.Join(f.main.Workspace, "evidence", "producer-expectation.json"))
		if err != nil {
			t.Fatal(err)
		}
		if err := contract.DecodeStrict(raw, &want); err != nil {
			t.Fatal(err)
		}
		want.RunID = f.peer.RunID
		if err := validateProducerExpectationBinding(want, f.main); err == nil {
			t.Fatal("peer expectation accepted for main binding")
		}
		// A separately pinned but wrong-run expectation cannot be installed into
		// the immutable journal, so the persisted expectation is also substituted
		// below to exercise the file-digest fail-closed path.
		raw = append([]byte(nil), raw...)
		raw = bytes.Replace(raw, []byte(f.main.RunID), []byte(f.peer.RunID), 1)
		write0600(t, filepath.Join(f.main.Workspace, "evidence", "producer-expectation.json"), raw)
		assertFreshProducerRejected(t, f)
	})
	t.Run("one-sided opt-in", func(t *testing.T) {
		f := newProducerVerifyFixture(t)
		peer := f.peer
		peer.InputDigests = cloneInputDigests(peer.InputDigests)
		delete(peer.InputDigests, producerExpectationInput)
		delete(peer.InputDigests, producerManifestInput)
		if _, _, err := verifyProducerPair(context.Background(), f.main.Workspace, f.peer.Workspace, f.main, peer); err == nil {
			t.Fatal("one-sided producer opt-in was accepted")
		}
	})
}

func TestProducerExpectationRejectsSeenCommitAndStateHeightSwap(t *testing.T) {
	f := newProducerVerifyFixture(t)
	raw, err := os.ReadFile(filepath.Join(f.main.Workspace, "evidence", "producer-expectation.json"))
	if err != nil {
		t.Fatal(err)
	}
	var want coregate.ProducerExpectation
	if err := contract.DecodeStrict(raw, &want); err != nil {
		t.Fatal(err)
	}
	if want.Height != f.main.Heights.Blockstore || want.Height != f.main.Heights.FirstRepaired || want.CometStateHeight != *f.main.Heights.Consensus {
		t.Fatalf("fixture height layout invalid: expect=%+v binding=%+v", want, f.main.Heights)
	}
	wrong := want
	wrong.Height = *f.main.Heights.Consensus
	wrong.BlockstoreHeight = *f.main.Heights.Consensus
	wrong.CometStateHeight = f.main.Heights.Blockstore
	if err := validateProducerExpectationBinding(wrong, f.main); err == nil {
		t.Fatal("seen-commit/blockstore/state height swap was accepted")
	}
}

func assertFreshProducerRejected(t *testing.T, f freshVerifyFixture) {
	t.Helper()
	if _, err := VerifyFresh(context.Background(), f.main.Workspace, f.main.RunID, f.mainCatalog, f.mainArtifact, f.peerCatalog, f.peerArtifact, f.roots, f.revocations, f.now); err == nil {
		t.Fatal("invalid producer evidence was accepted")
	}
	_, _, _, receipts, err := lifecycle.ReadStoredSnapshot(f.main.Workspace)
	if err != nil {
		t.Fatal(err)
	}
	if hasPhase(receipts, contract.Verify) {
		t.Fatal("failed producer verification recorded successful Verify")
	}
}

func mustFreshDigest(t *testing.T, result evidence.Result) string {
	t.Helper()
	digest, err := evidence.FreshPayloadDigest(result)
	if err != nil {
		t.Fatal(err)
	}
	return digest
}

func newProducerVerifyFixture(t *testing.T) freshVerifyFixture {
	t.Helper()
	base := t.TempDir()
	mainRoot, peerRoot := filepath.Join(base, "main"), filepath.Join(base, "peer")
	comet := makeSessionCometEvidence(t)
	height := comet.want.Height
	main := freshBinding(mainRoot, "producer-main", "owner-main", height)
	peer := freshBinding(peerRoot, "producer-peer", "owner-peer", height)
	for _, binding := range []*contract.RunBinding{&main, &peer} {
		binding.ChainID = comet.want.ChainID
		binding.Heights.Blockstore, binding.Heights.App, binding.Heights.FirstRepaired = height, height-1, height
		binding.Heights.Consensus = int64Pointer(height - 1)
		binding.AppHashHeight = height - 1
		binding.BlockID, binding.AppHash = comet.want.BlockID, comet.want.HeaderAppHash
		binding.InputDigests["recovery-binary"] = strings.Repeat("b", 64)
		binding.InputDigests["producer-binary"] = strings.Repeat("e", 64)
	}
	main.Paths["peer_workspace"] = peerRoot
	mainBytes := pinSessionProducerEvidence(t, main, comet)
	peerBytes := pinSessionProducerEvidence(t, peer, comet)
	seedCatalog := sha256.Sum256([]byte("producer-fixture-catalog-key"))
	seedCore := sha256.Sum256([]byte("producer-fixture-core-key"))
	catalogKey, coreKey := ed25519.NewKeyFromSeed(seedCatalog[:]), ed25519.NewKeyFromSeed(seedCore[:])
	nowTime := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	now := func() time.Time { return nowTime }
	roots := []input.TrustRoot{
		{KeyID: "catalog", Role: "catalog", Scopes: map[string]bool{"epoch-length-live-update": true}, PublicKey: catalogKey.Public().(ed25519.PublicKey)},
		{KeyID: "core", Role: "core", Scopes: map[string]bool{"stage": true}, PublicKey: coreKey.Public().(ed25519.PublicKey)},
	}
	revocations := input.RevocationSnapshot{ValidUntil: nowTime.Add(time.Hour), Revoked: map[string]bool{}}
	mainCatalog, mainArtifact := signedPolicies(t, main, catalogKey, coreKey, nowTime)
	main.InputDigests["catalog"], main.InputDigests["recovery_artifact"] = contract.PayloadDigest(mainCatalog.Payload), contract.PayloadDigest(mainArtifact.Payload)
	peerCatalog, peerArtifact := signedPolicies(t, peer, catalogKey, coreKey, nowTime)
	peer.InputDigests["catalog"], peer.InputDigests["recovery_artifact"] = contract.PayloadDigest(peerCatalog.Payload), contract.PayloadDigest(peerArtifact.Payload)
	for _, binding := range []contract.RunBinding{main, peer} {
		if err := contract.ValidateBinding(binding); err != nil {
			t.Fatal(err)
		}
	}
	createJournal(t, main)
	createJournal(t, peer)
	snapshot := contract.Snapshot{Stores: []contract.LogicalStore{{Name: "auth", Entries: []contract.Entry{}}}}
	writeSnapshots(t, mainRoot, map[string]contract.Snapshot{"topology.before": snapshot})
	writeSnapshots(t, peerRoot, map[string]contract.Snapshot{"topology.before": snapshot})
	seedCaptureReceipt(t, main, snapshot)
	seedCaptureReceipt(t, peer, snapshot)
	for _, binding := range []contract.RunBinding{main, peer} {
		stage := &testStageAdapter{after: snapshot}
		if _, err := ExecuteStage(context.Background(), binding.Workspace, binding.RunID, stage); err != nil {
			t.Fatal(err)
		}
		run := &testRunAdapter{out: RunSnapshots{MigrationBefore: snapshot, MigrationAfter: snapshot, BlockBefore: snapshot, BlockAfter: snapshot}}
		if _, err := ExecuteRun(context.Background(), binding.Workspace, binding.RunID, run); err != nil {
			t.Fatal(err)
		}
	}
	writeSessionProducerEvidence(t, mainRoot, mainBytes)
	writeSessionProducerEvidence(t, peerRoot, peerBytes)
	return freshVerifyFixture{main: main, peer: peer, mainCatalog: mainCatalog, mainArtifact: mainArtifact, peerCatalog: peerCatalog, peerArtifact: peerArtifact, roots: roots, revocations: revocations, now: now}
}

func int64Pointer(v int64) *int64 { return &v }

func seedCaptureReceipt(t *testing.T, binding contract.RunBinding, snapshot contract.Snapshot) {
	t.Helper()
	digest, err := evidence.SnapshotDigest(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	journal, err := lifecycle.Open(binding.Workspace, binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordIntent("frozen_export_copy", contract.Receipt{Phase: contract.Capture}); err != nil {
		t.Fatal(err)
	}
	if err := journal.RecordResult(contract.Receipt{Phase: contract.Capture, State: contract.Succeeded, EvidenceDigests: map[string]string{"topology.before": digest}}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
}

type sessionCometEvidence struct {
	want                      coregate.ProducerExpectation
	commit, validators, block []byte
}

func makeSessionCometEvidence(t *testing.T) sessionCometEvidence {
	t.Helper()
	const height int64 = 370
	const chain = "producer-contract-comet-0.38.21"
	const partSize uint32 = 64
	validators := make([]*tmtypes.Validator, 0, 4)
	priv := map[string]cmtcryptoed.PrivKey{}
	for i := 0; i < 4; i++ {
		key := cmtcryptoed.GenPrivKey()
		v := tmtypes.NewValidator(key.PubKey(), 10)
		validators = append(validators, v)
		priv[string(v.Address)] = key
	}
	set := tmtypes.NewValidatorSet(validators)
	priorID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(bytes.Repeat([]byte{0x11}, 32)), PartSetHeader: tmtypes.PartSetHeader{Total: 1, Hash: cmtbytes.HexBytes(bytes.Repeat([]byte{0x22}, 32))}}
	priorCommit := signSessionCommit(t, set, priv, chain, height-1, priorID)
	block := tmtypes.MakeBlock(height, nil, priorCommit, nil)
	block.Header.ChainID, block.Header.Time, block.Header.LastBlockID = chain, time.Unix(1_800_000_000, 0).UTC(), priorID
	block.Header.ValidatorsHash, block.Header.NextValidatorsHash = set.Hash(), set.Hash()
	block.Header.ConsensusHash, block.Header.AppHash, block.Header.LastResultsHash = bytes.Repeat([]byte{0x33}, 32), bytes.Repeat([]byte{0x44}, 32), bytes.Repeat([]byte{0x55}, 32)
	block.Header.ProposerAddress = append([]byte(nil), set.Validators[0].Address...)
	if err := block.ValidateBasic(); err != nil {
		t.Fatal(err)
	}
	parts, err := block.MakePartSet(partSize)
	if err != nil {
		t.Fatal(err)
	}
	blockID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(block.Hash()), PartSetHeader: parts.Header()}
	commit := signSessionCommit(t, set, priv, chain, height, blockID)
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
	blockProto, err := block.ToProto()
	if err != nil {
		t.Fatal(err)
	}
	blockRaw, err := proto.Marshal(blockProto)
	if err != nil {
		t.Fatal(err)
	}
	return sessionCometEvidence{want: coregate.ProducerExpectation{NodeID: "producer-node", ChainID: chain, Height: height,
		ApplicationHeight: height - 1, CometStateHeight: height - 1, BlockstoreHeight: height,
		BlockID: hex.EncodeToString(blockID.Hash), PartSetHash: hex.EncodeToString(blockID.PartSetHeader.Hash), PartSetTotal: blockID.PartSetHeader.Total,
		HeaderAppHash: hex.EncodeToString(block.Header.AppHash), SeenCommitHash: hex.EncodeToString(commit.Hash()), ValidatorSetHash: hex.EncodeToString(set.Hash()),
		ValidatorSetSource: "validators", ValidatorSetHeight: height, BlockPartSize: partSize}, commit: commitRaw, validators: validatorRaw, block: blockRaw}
}

func signSessionCommit(t *testing.T, set *tmtypes.ValidatorSet, priv map[string]cmtcryptoed.PrivKey, chain string, height int64, id tmtypes.BlockID) *tmtypes.Commit {
	t.Helper()
	commit := &tmtypes.Commit{Height: height, Round: 0, BlockID: id, Signatures: make([]tmtypes.CommitSig, set.Size())}
	for i, v := range set.Validators {
		vote := tmtypes.Vote{Type: cmtproto.PrecommitType, Height: height, Round: 0, BlockID: id, Timestamp: time.Unix(1_800_000_100+int64(i), 0).UTC(), ValidatorAddress: v.Address, ValidatorIndex: int32(i)}
		sig, err := priv[string(v.Address)].Sign(tmtypes.VoteSignBytes(chain, vote.ToProto()))
		if err != nil {
			t.Fatal(err)
		}
		commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagCommit, ValidatorAddress: v.Address, Timestamp: vote.Timestamp, Signature: sig}
	}
	return commit
}

type sessionProducerFiles struct{ expectation, manifest, commit, validators, block []byte }

func pinSessionProducerEvidence(t *testing.T, binding contract.RunBinding, fixture sessionCometEvidence) sessionProducerFiles {
	t.Helper()
	want := fixture.want
	want.RunID, want.GenesisSHA256 = binding.RunID, binding.GenesisSHA256
	want.RecoveryArtifactSHA256, want.ProducerSHA256 = binding.InputDigests["recovery-binary"], binding.InputDigests["producer-binary"]
	expectation, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	exit := 0
	manifest := coregate.ProducerManifest{SchemaVersion: coregate.ProducerManifestSchema, Phase: coregate.ProducerPhaseBeforeRecovery,
		RunID: want.RunID, NodeID: want.NodeID, ChainID: want.ChainID, GenesisSHA256: want.GenesisSHA256, RecoveryArtifactSHA256: want.RecoveryArtifactSHA256,
		Height: want.Height, BlockID: want.BlockID, PartSetHash: want.PartSetHash, PartSetTotal: want.PartSetTotal, HeaderAppHash: want.HeaderAppHash,
		SeenCommitHash: want.SeenCommitHash, ValidatorSetHash: want.ValidatorSetHash, CometVersion: coregate.ProducerCometVersion,
		Producer: "gnklab-state-inspect", ProducerVersion: "synthetic", ProducerSHA256: want.ProducerSHA256, ProducerSourceCommit: strings.Repeat("c", 40),
		Command: []string{"gnklab-state-inspect", "--readonly"}, ExitCode: &exit, Provenance: "synthetic actual-format bytes", ObservedUTC: "2026-10-19T12:00:00Z",
		ApplicationHeight: want.ApplicationHeight, CometStateHeight: want.CometStateHeight, BlockstoreHeight: want.BlockstoreHeight,
		ValidatorSetSource: want.ValidatorSetSource, ValidatorSetHeight: want.ValidatorSetHeight,
		SeenCommit: sessionProducerPin("seen_commit.bin", fixture.commit), ValidatorSet: sessionProducerPin("validator_set.bin", fixture.validators), BlockH: sessionProducerPin("block-h.bin", fixture.block)}
	manifestRaw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	binding.InputDigests[producerExpectationInput] = contract.PayloadDigest(expectation)
	binding.InputDigests[producerManifestInput] = contract.PayloadDigest(manifestRaw)
	return sessionProducerFiles{expectation: expectation, manifest: manifestRaw, commit: fixture.commit, validators: fixture.validators, block: fixture.block}
}

func sessionProducerPin(name string, raw []byte) coregate.ProducerFile {
	sum := sha256.Sum256(raw)
	return coregate.ProducerFile{Filename: name, Size: int64(len(raw)), SHA256: hex.EncodeToString(sum[:])}
}

func writeSessionProducerEvidence(t *testing.T, root string, f sessionProducerFiles) {
	t.Helper()
	dir := filepath.Join(root, "evidence")
	for name, raw := range map[string][]byte{"producer-expectation.json": f.expectation, "producer-manifest.json": f.manifest, "seen_commit.bin": f.commit, "validator_set.bin": f.validators, "block-h.bin": f.block} {
		write0600(t, filepath.Join(dir, name), raw)
	}
}
