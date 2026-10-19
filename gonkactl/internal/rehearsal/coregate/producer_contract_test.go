package coregate

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"

	cmtcryptoed "github.com/cometbft/cometbft/crypto/ed25519"
	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
)

type producerFixture struct {
	manifest     ProducerManifest
	manifestRaw  []byte
	commitRaw    []byte
	validatorRaw []byte
	blockRaw     []byte
	want         ProducerExpectation
	set          *tmtypes.ValidatorSet
	priv         map[string]cmtcryptoed.PrivKey
}

func makeProducerFixture(t *testing.T, signerCount int) producerFixture {
	t.Helper()
	const height = int64(370)
	const chainID = "producer-contract-comet-0.38.21"
	validators := make([]*tmtypes.Validator, 0, 4)
	priv := make(map[string]cmtcryptoed.PrivKey)
	for i := 0; i < 4; i++ {
		key := cmtcryptoed.GenPrivKey()
		validator := tmtypes.NewValidator(key.PubKey(), 10)
		validators = append(validators, validator)
		priv[string(validator.Address)] = key
	}
	set := tmtypes.NewValidatorSet(validators)
	priorID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(bytes.Repeat([]byte{0x11}, 32)), PartSetHeader: tmtypes.PartSetHeader{Total: 1, Hash: cmtbytes.HexBytes(bytes.Repeat([]byte{0x22}, 32))}}
	priorCommit := signProducerCommit(t, set, priv, chainID, height-1, priorID, 3)
	block := tmtypes.MakeBlock(height, nil, priorCommit, nil)
	block.Header.ChainID = chainID
	block.Header.Time = time.Unix(1_800_000_000, 0).UTC()
	block.Header.LastBlockID = priorID
	block.Header.ValidatorsHash = set.Hash()
	block.Header.NextValidatorsHash = set.Hash()
	block.Header.ConsensusHash = bytes.Repeat([]byte{0x33}, 32)
	block.Header.AppHash = bytes.Repeat([]byte{0x44}, 32)
	block.Header.LastResultsHash = bytes.Repeat([]byte{0x55}, 32)
	block.Header.ProposerAddress = append([]byte(nil), set.Validators[0].Address...)
	if err := block.ValidateBasic(); err != nil {
		t.Fatalf("construct Block H: %v", err)
	}
	partSet, err := block.MakePartSet(fixturePartSize)
	if err != nil {
		t.Fatal(err)
	}
	blockID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(block.Hash()), PartSetHeader: partSet.Header()}
	commit := signProducerCommit(t, set, priv, chainID, height, blockID, signerCount)
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
	want := ProducerExpectation{
		RunID: "run-actual-17", NodeID: "validator-1", ChainID: chainID,
		GenesisSHA256: strings.Repeat("a", 64), RecoveryArtifactSHA256: strings.Repeat("b", 64), ProducerSHA256: strings.Repeat("d", 64), Height: height,
		ApplicationHeight: height - 1, CometStateHeight: height - 1, BlockstoreHeight: height,
		BlockID: hex.EncodeToString(blockID.Hash), PartSetHash: hex.EncodeToString(blockID.PartSetHeader.Hash),
		PartSetTotal: blockID.PartSetHeader.Total, HeaderAppHash: hex.EncodeToString(block.Header.AppHash),
		SeenCommitHash: hex.EncodeToString(commit.Hash()), ValidatorSetHash: hex.EncodeToString(set.Hash()),
		ValidatorSetSource: "validators", ValidatorSetHeight: height, BlockPartSize: fixturePartSize,
	}
	exitCode := 0
	manifest := ProducerManifest{
		SchemaVersion: ProducerManifestSchema, Phase: ProducerPhaseBeforeRecovery,
		RunID: want.RunID, NodeID: want.NodeID, ChainID: want.ChainID, GenesisSHA256: want.GenesisSHA256,
		RecoveryArtifactSHA256: want.RecoveryArtifactSHA256, Height: want.Height, BlockID: want.BlockID,
		PartSetHash: want.PartSetHash, PartSetTotal: want.PartSetTotal, HeaderAppHash: want.HeaderAppHash,
		SeenCommitHash: want.SeenCommitHash, ValidatorSetHash: want.ValidatorSetHash, CometVersion: ProducerCometVersion,
		Producer: "gnklab-state-inspect", ProducerVersion: "test-build", ProducerSHA256: strings.Repeat("d", 64), ProducerSourceCommit: strings.Repeat("c", 40),
		Command: []string{"gnklab-state-inspect", "--source-dir", "/fixture"}, ExitCode: &exitCode,
		Provenance: "synthetic actual-format byte fixture", ObservedUTC: "2026-10-19T12:00:00Z",
		ApplicationHeight: height - 1, CometStateHeight: height - 1, BlockstoreHeight: height,
		ValidatorSetSource: want.ValidatorSetSource, ValidatorSetHeight: height,
		SeenCommit: producerFilePin("seen_commit.bin", commitRaw), ValidatorSet: producerFilePin("validator_set.bin", validatorRaw), BlockH: producerFilePin("block-h.bin", blockRaw),
	}
	manifestRaw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return producerFixture{manifest: manifest, manifestRaw: manifestRaw, commitRaw: commitRaw, validatorRaw: validatorRaw, blockRaw: blockRaw, want: want, set: set, priv: priv}
}

func signProducerCommit(t *testing.T, set *tmtypes.ValidatorSet, priv map[string]cmtcryptoed.PrivKey, chainID string, height int64, blockID tmtypes.BlockID, signerCount int) *tmtypes.Commit {
	t.Helper()
	commit := &tmtypes.Commit{Height: height, Round: 0, BlockID: blockID, Signatures: make([]tmtypes.CommitSig, set.Size())}
	for i, validator := range set.Validators {
		if i >= signerCount {
			commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagAbsent}
			continue
		}
		vote := tmtypes.Vote{Type: cmtproto.PrecommitType, Height: height, Round: 0, BlockID: blockID, Timestamp: time.Unix(1_800_000_100+int64(i), 0).UTC(), ValidatorAddress: validator.Address, ValidatorIndex: int32(i)}
		sig, err := priv[string(validator.Address)].Sign(tmtypes.VoteSignBytes(chainID, vote.ToProto()))
		if err != nil {
			t.Fatal(err)
		}
		commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagCommit, ValidatorAddress: validator.Address, Timestamp: vote.Timestamp, Signature: sig}
	}
	return commit
}

func producerFilePin(name string, raw []byte) ProducerFile {
	sum := sha256.Sum256(raw)
	return ProducerFile{Filename: name, Size: int64(len(raw)), SHA256: hex.EncodeToString(sum[:])}
}

func TestVerifyProducerEvidenceAcceptsRealCometEvidenceAtHWithoutHPlusOne(t *testing.T) {
	f := makeProducerFixture(t, 3)
	got, err := VerifyProducerEvidence(context.Background(), f.manifestRaw, f.commitRaw, f.validatorRaw, f.blockRaw, f.want)
	if err != nil {
		t.Fatal(err)
	}
	if got.Quorum.Signers != 3 || got.Quorum.SignedPower != 30 || got.Quorum.TotalPower != 40 || got.Block.Height != f.want.Height || got.Block.BlockID != f.want.BlockID || got.Boundary == "" {
		t.Fatalf("unexpected producer verification: %+v", got)
	}
	if strings.Contains(string(f.manifestRaw), "h_plus_one") {
		t.Fatal("pre-recovery manifest unexpectedly contains H+1 evidence")
	}
}

func TestVerifyProducerEvidenceRejectsSubstitutionAndMalformedPhase(t *testing.T) {
	f := makeProducerFixture(t, 3)
	t.Run("raw block substitution", func(t *testing.T) {
		bad := append([]byte(nil), f.blockRaw...)
		bad[len(bad)-1] ^= 0x01
		if _, err := VerifyProducerEvidence(context.Background(), f.manifestRaw, f.commitRaw, f.validatorRaw, bad, f.want); err == nil {
			t.Fatal("accepted block bytes not matching pinned digest")
		}
	})
	t.Run("wrong trusted binding", func(t *testing.T) {
		want := f.want
		want.GenesisSHA256 = strings.Repeat("d", 64)
		if _, err := VerifyProducerEvidence(context.Background(), f.manifestRaw, f.commitRaw, f.validatorRaw, f.blockRaw, want); err == nil {
			t.Fatal("accepted producer manifest from another genesis binding")
		}
	})
	t.Run("wrong phase", func(t *testing.T) {
		manifest := f.manifest
		manifest.Phase = "post-standard"
		raw, _ := json.Marshal(manifest)
		if _, err := VerifyProducerEvidence(context.Background(), raw, f.commitRaw, f.validatorRaw, f.blockRaw, f.want); err == nil {
			t.Fatal("accepted post-standard phase as pre-recovery source")
		}
	})
	t.Run("wrong chain", func(t *testing.T) {
		want := f.want
		want.ChainID = "other-chain"
		if _, err := VerifyProducerEvidence(context.Background(), f.manifestRaw, f.commitRaw, f.validatorRaw, f.blockRaw, want); err == nil {
			t.Fatal("accepted wrong chain binding")
		}
	})
	t.Run("wrong H", func(t *testing.T) {
		want := f.want
		want.Height++
		if _, err := VerifyProducerEvidence(context.Background(), f.manifestRaw, f.commitRaw, f.validatorRaw, f.blockRaw, want); err == nil {
			t.Fatal("accepted wrong height")
		}
	})
	t.Run("frozen pre-recovery stores must be H-1/H-1/H", func(t *testing.T) {
		manifest := f.manifest
		manifest.ApplicationHeight = f.want.Height
		manifest.CometStateHeight = f.want.Height
		raw, _ := json.Marshal(manifest)
		if _, err := VerifyProducerEvidence(context.Background(), raw, f.commitRaw, f.validatorRaw, f.blockRaw, f.want); err == nil {
			t.Fatal("accepted all-stores-at-H layout instead of frozen H-1/H-1/H")
		}
		wrongWant := f.want
		wrongWant.ApplicationHeight = wrongWant.Height
		wrongWant.CometStateHeight = wrongWant.Height
		if _, err := VerifyProducerEvidence(context.Background(), f.manifestRaw, f.commitRaw, f.validatorRaw, f.blockRaw, wrongWant); err == nil {
			t.Fatal("accepted expectation that contradicts frozen H-1/H-1/H phase")
		}
	})
	t.Run("truncated block", func(t *testing.T) {
		manifest := f.manifest
		truncated := f.blockRaw[:len(f.blockRaw)-1]
		manifest.BlockH = producerFilePin("block-h.bin", truncated)
		raw, _ := json.Marshal(manifest)
		if _, err := VerifyProducerEvidence(context.Background(), raw, f.commitRaw, f.validatorRaw, truncated, f.want); err == nil {
			t.Fatal("accepted truncated protobuf block")
		}
	})
	t.Run("insufficient voting power", func(t *testing.T) {
		minority := makeProducerFixture(t, 2)
		if _, err := VerifyProducerEvidence(context.Background(), minority.manifestRaw, minority.commitRaw, minority.validatorRaw, minority.blockRaw, minority.want); err == nil {
			t.Fatal("accepted two-of-four commit")
		}
	})
	t.Run("wrong validator set", func(t *testing.T) {
		other := makeProducerFixture(t, 3)
		manifest := f.manifest
		manifest.ValidatorSet = producerFilePin("validator_set.bin", other.validatorRaw)
		manifest.ValidatorSetHash = other.want.ValidatorSetHash
		want := f.want
		want.ValidatorSetHash = other.want.ValidatorSetHash
		raw, _ := json.Marshal(manifest)
		if _, err := VerifyProducerEvidence(context.Background(), raw, f.commitRaw, other.validatorRaw, f.blockRaw, want); err == nil {
			t.Fatal("accepted signatures against a substituted validator set")
		}
	})
	t.Run("block header validator hash differs", func(t *testing.T) {
		bad := f
		var protoBlock cmtproto.Block
		if err := proto.Unmarshal(bad.blockRaw, &protoBlock); err != nil {
			t.Fatal(err)
		}
		block, err := tmtypes.BlockFromProto(&protoBlock)
		if err != nil {
			t.Fatal(err)
		}
		block.Header.ValidatorsHash = bytes.Repeat([]byte{0xee}, 32)
		blockProto, err := block.ToProto()
		if err != nil {
			t.Fatal(err)
		}
		bad.blockRaw, err = proto.Marshal(blockProto)
		if err != nil {
			t.Fatal(err)
		}
		partSet, err := block.MakePartSet(fixturePartSize)
		if err != nil {
			t.Fatal(err)
		}
		blockID := tmtypes.BlockID{Hash: cmtbytes.HexBytes(block.Hash()), PartSetHeader: partSet.Header()}
		commit := signProducerCommit(t, bad.set, bad.priv, bad.want.ChainID, bad.want.Height, blockID, 3)
		bad.commitRaw, err = proto.Marshal(commit.ToProto())
		if err != nil {
			t.Fatal(err)
		}
		bad.want.BlockID = hex.EncodeToString(blockID.Hash)
		bad.want.PartSetHash = hex.EncodeToString(blockID.PartSetHeader.Hash)
		bad.want.PartSetTotal = blockID.PartSetHeader.Total
		bad.want.SeenCommitHash = hex.EncodeToString(commit.Hash())
		bad.manifest.BlockID = bad.want.BlockID
		bad.manifest.PartSetHash = bad.want.PartSetHash
		bad.manifest.PartSetTotal = bad.want.PartSetTotal
		bad.manifest.SeenCommitHash = bad.want.SeenCommitHash
		bad.manifest.BlockH = producerFilePin("block-h.bin", bad.blockRaw)
		bad.manifest.SeenCommit = producerFilePin("seen_commit.bin", bad.commitRaw)
		bad.manifestRaw, err = json.Marshal(bad.manifest)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := VerifyProducerEvidence(context.Background(), bad.manifestRaw, bad.commitRaw, bad.validatorRaw, bad.blockRaw, bad.want); err == nil || !strings.Contains(err.Error(), "ValidatorsHash") {
			t.Fatalf("accepted Block H with a different ValidatorsHash: %v", err)
		}
	})
}

func TestVerifyProducerEvidenceRequiresExplicitProducerContractMetadata(t *testing.T) {
	f := makeProducerFixture(t, 3)
	for name, mutate := range map[string]func(*ProducerManifest){
		"missing exit code":            func(m *ProducerManifest) { m.ExitCode = nil },
		"nonzero exit code":            func(m *ProducerManifest) { code := 1; m.ExitCode = &code },
		"wrong application height":     func(m *ProducerManifest) { m.ApplicationHeight++ },
		"wrong state height":           func(m *ProducerManifest) { m.CometStateHeight++ },
		"wrong blockstore height":      func(m *ProducerManifest) { m.BlockstoreHeight++ },
		"unsupported validator source": func(m *ProducerManifest) { m.ValidatorSetSource = "next_validators" },
		"wrong validator height":       func(m *ProducerManifest) { m.ValidatorSetHeight++ },
		"bad producer digest":          func(m *ProducerManifest) { m.ProducerSHA256 = "not-a-digest" },
		"empty command":                func(m *ProducerManifest) { m.Command = nil },
	} {
		t.Run(name, func(t *testing.T) {
			manifest := f.manifest
			mutate(&manifest)
			raw, err := json.Marshal(manifest)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := VerifyProducerEvidence(context.Background(), raw, f.commitRaw, f.validatorRaw, f.blockRaw, f.want); err == nil {
				t.Fatal("accepted incomplete producer contract metadata")
			}
		})
	}
}

func TestVerifyPostStandardHPlusOneIsSeparateAndChecksLink(t *testing.T) {
	f := makeCometFixture(t, 3)
	priorAppHash := bytes.Repeat([]byte{0x75}, 32)
	raw, block := makeHPlusOneBlock(t, f, priorAppHash)
	partSet, err := block.MakePartSet(fixturePartSize)
	if err != nil {
		t.Fatal(err)
	}
	want := HPlusOneExpectation{
		RunID: "run-1", NodeID: "n1", ChainID: f.chain, Height: f.height,
		PreviousBlockID: hex.EncodeToString(f.blockID.Hash), PreviousPartSetHash: hex.EncodeToString(f.blockID.PartSetHeader.Hash), PreviousPartSetTotal: f.blockID.PartSetHeader.Total,
		HeaderAppHash: hex.EncodeToString(priorAppHash), BlockID: hex.EncodeToString(block.Hash()), PartSetHash: hex.EncodeToString(partSet.Header().Hash), PartSetTotal: partSet.Header().Total,
	}
	verified, err := VerifyPostStandardHPlusOne(context.Background(), raw, CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize}, want)
	if err != nil || verified.Phase != "post-standard" || verified.Size != int64(len(raw)) || verified.SHA256 == "" {
		t.Fatalf("valid post-standard block failed: %+v %v", verified, err)
	}
	want.PreviousPartSetTotal++
	if _, err := VerifyPostStandardHPlusOne(context.Background(), raw, CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize}, want); err == nil {
		t.Fatal("accepted H+1 block linked to a different H part set")
	}
}

func TestProducerEvidenceAPIsRejectNilContext(t *testing.T) {
	f := makeProducerFixture(t, 3)
	if _, err := VerifyProducerEvidence(nil, f.manifestRaw, f.commitRaw, f.validatorRaw, f.blockRaw, f.want); err == nil {
		t.Fatal("accepted nil context for producer evidence")
	}
	if _, err := VerifyPostStandardHPlusOne(nil, []byte{1}, testBlockDecoder{}, HPlusOneExpectation{}); err == nil {
		t.Fatal("accepted nil context for H+1 evidence")
	}
}
