package coregate

import (
	"bytes"
	"context"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	cmtcryptoed "github.com/cometbft/cometbft/crypto/ed25519"
	cmtbytes "github.com/cometbft/cometbft/libs/bytes"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
)

const fixtureChainID = "coregate-comet-0.38.21-test"
const fixtureHeight = int64(370)
const fixturePartSize = uint32(64)

type cometFixture struct {
	chain          string
	height         int64
	blockID        tmtypes.BlockID
	set            *tmtypes.ValidatorSet
	commit         *tmtypes.Commit
	commitBytes    []byte
	validatorBytes []byte
	commitHash     string
	validatorHash  string
}

func makeCometFixture(t *testing.T, signerCount int) cometFixture {
	t.Helper()
	const validatorCount = 4
	privByAddress := make(map[string]cmtcryptoed.PrivKey, validatorCount)
	validators := make([]*tmtypes.Validator, 0, validatorCount)
	for i := 0; i < validatorCount; i++ {
		priv := cmtcryptoed.GenPrivKey()
		pub := priv.PubKey()
		validator := tmtypes.NewValidator(pub, 10)
		validators = append(validators, validator)
		privByAddress[string(validator.Address)] = priv
	}
	set := tmtypes.NewValidatorSet(validators)
	blockID := tmtypes.BlockID{
		Hash:          cmtbytes.HexBytes(bytes.Repeat([]byte{0x31}, 32)),
		PartSetHeader: tmtypes.PartSetHeader{Total: 2, Hash: cmtbytes.HexBytes(bytes.Repeat([]byte{0x42}, 32))},
	}
	commit := &tmtypes.Commit{Height: fixtureHeight, Round: 0, BlockID: blockID, Signatures: make([]tmtypes.CommitSig, set.Size())}
	for i, validator := range set.Validators {
		if i >= signerCount {
			commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagAbsent}
			continue
		}
		timestamp := time.Unix(1_800_000_000+int64(i), 0).UTC()
		commit.Signatures[i] = tmtypes.CommitSig{BlockIDFlag: tmtypes.BlockIDFlagCommit, ValidatorAddress: validator.Address, Timestamp: timestamp}
		priv := privByAddress[string(validator.Address)]
		sig, err := priv.Sign(commit.VoteSignBytes(fixtureChainID, int32(i)))
		if err != nil {
			t.Fatal(err)
		}
		commit.Signatures[i].Signature = sig
	}
	commitProto := commit.ToProto()
	commitBytes, err := proto.Marshal(commitProto)
	if err != nil {
		t.Fatal(err)
	}
	setProto, err := set.ToProto()
	if err != nil {
		t.Fatal(err)
	}
	validatorBytes, err := proto.Marshal(setProto)
	if err != nil {
		t.Fatal(err)
	}
	return cometFixture{
		chain:          fixtureChainID,
		height:         fixtureHeight,
		blockID:        blockID,
		set:            set,
		commit:         commit,
		commitBytes:    commitBytes,
		validatorBytes: validatorBytes,
		commitHash:     hex.EncodeToString(commit.Hash()),
		validatorHash:  hex.EncodeToString(set.Hash()),
	}
}

func (f cometFixture) verify(ctx context.Context, chain string, commit, validators []byte, height int64, commitHash, validatorHash string) (QuorumProof, error) {
	return (CometCommitVerifier{}).VerifySeenCommit(ctx, chain, commit, validators,
		hex.EncodeToString(f.blockID.Hash), hex.EncodeToString(f.blockID.PartSetHeader.Hash), f.blockID.PartSetHeader.Total,
		height, commitHash, validatorHash)
}

func TestCometCommitVerifierAcceptsGenuineThreeOfFourSignatures(t *testing.T) {
	f := makeCometFixture(t, 3)
	proof, err := f.verify(context.Background(), f.chain, f.commitBytes, f.validatorBytes, f.height, f.commitHash, f.validatorHash)
	if err != nil {
		t.Fatal(err)
	}
	if proof.BlockID != hex.EncodeToString(f.blockID.Hash) || proof.ValidatorSetHash != f.validatorHash || proof.SignedPower != 30 || proof.TotalPower != 40 || proof.Signers != 3 {
		t.Fatalf("unexpected verified quorum proof: %+v", proof)
	}
}

func TestCometCommitVerifierRejectsTamperWrongChainWrongHeightTruncationAndWrongSet(t *testing.T) {
	f := makeCometFixture(t, 3)
	t.Run("tampered signature", func(t *testing.T) {
		mutated := *f.commit
		mutated.Signatures = append([]tmtypes.CommitSig(nil), f.commit.Signatures...)
		mutated.Signatures[0].Signature = append([]byte(nil), mutated.Signatures[0].Signature...)
		mutated.Signatures[0].Signature[0] ^= 0xff
		mutatedProto := mutated.ToProto()
		mutatedForHash, err := tmtypes.CommitFromProto(mutatedProto)
		if err != nil {
			t.Fatal(err)
		}
		b, marshalErr := proto.Marshal(mutatedProto)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		if _, err := f.verify(context.Background(), f.chain, b, f.validatorBytes, f.height, hex.EncodeToString(mutatedForHash.Hash()), f.validatorHash); err == nil || !strings.Contains(err.Error(), "signature/quorum") {
			t.Fatalf("tampered signature accepted or failed at wrong check: %v", err)
		}
	})
	t.Run("wrong chain", func(t *testing.T) {
		if _, err := f.verify(context.Background(), "other-chain", f.commitBytes, f.validatorBytes, f.height, f.commitHash, f.validatorHash); err == nil {
			t.Fatal("commit signed for another chain was accepted")
		}
	})
	t.Run("wrong height", func(t *testing.T) {
		if _, err := f.verify(context.Background(), f.chain, f.commitBytes, f.validatorBytes, f.height+1, f.commitHash, f.validatorHash); err == nil || !strings.Contains(err.Error(), "does not equal expected H") {
			t.Fatalf("wrong H was not rejected: %v", err)
		}
	})
	t.Run("truncated protobuf", func(t *testing.T) {
		if _, err := f.verify(context.Background(), f.chain, f.commitBytes[:len(f.commitBytes)-1], f.validatorBytes, f.height, f.commitHash, f.validatorHash); err == nil {
			t.Fatal("truncated commit protobuf was accepted")
		}
	})
	t.Run("wrong validator set", func(t *testing.T) {
		other := makeCometFixture(t, 3)
		if _, err := f.verify(context.Background(), f.chain, f.commitBytes, other.validatorBytes, f.height, f.commitHash, f.validatorHash); err == nil || !strings.Contains(err.Error(), "validator-set hash differs") {
			t.Fatalf("substituted validator set was not rejected: %v", err)
		}
	})
	t.Run("insufficient voting power", func(t *testing.T) {
		minority := makeCometFixture(t, 2)
		if _, err := minority.verify(context.Background(), minority.chain, minority.commitBytes, minority.validatorBytes, minority.height, minority.commitHash, minority.validatorHash); err == nil {
			t.Fatal("two of four validators met CometBFT's strict +2/3 threshold")
		}
	})
}

func makeHPlusOneBlock(t *testing.T, f cometFixture, appHash []byte) ([]byte, *tmtypes.Block) {
	t.Helper()
	block := tmtypes.MakeBlock(f.height+1, nil, f.commit, nil)
	block.Header.ChainID = f.chain
	block.Header.Time = time.Unix(1_800_000_100, 0).UTC()
	block.Header.LastBlockID = f.blockID
	block.Header.ValidatorsHash = f.set.Hash()
	block.Header.NextValidatorsHash = f.set.Hash()
	block.Header.ConsensusHash = bytes.Repeat([]byte{0x53}, 32)
	block.Header.AppHash = append([]byte(nil), appHash...)
	block.Header.LastResultsHash = bytes.Repeat([]byte{0x64}, 32)
	block.Header.ProposerAddress = append([]byte(nil), f.set.Validators[0].Address...)
	if err := block.ValidateBasic(); err != nil {
		t.Fatalf("construct H+1 block: %v", err)
	}
	pb, err := block.ToProto()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := proto.Marshal(pb)
	if err != nil {
		t.Fatal(err)
	}
	return raw, block
}

func TestCometBlockDecoderAndReaderVerifyCanonicalHPlusOneLink(t *testing.T) {
	f := makeCometFixture(t, 3)
	priorAppHash := bytes.Repeat([]byte{0x75}, 32)
	raw, block := makeHPlusOneBlock(t, f, priorAppHash)
	decoded, err := (CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize}).DecodeHPlusOneBlock(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	partSet, err := block.MakePartSet(fixturePartSize)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Height != f.height+1 || decoded.ChainID != f.chain || decoded.HeaderAppHash != hex.EncodeToString(priorAppHash) || decoded.PreviousBlockID != hex.EncodeToString(f.blockID.Hash) || decoded.PreviousPartSetHash != hex.EncodeToString(f.blockID.PartSetHeader.Hash) || decoded.PreviousPartSetTotal != f.blockID.PartSetHeader.Total || decoded.BlockID != hex.EncodeToString(block.Hash()) || decoded.PartSetHash != hex.EncodeToString(partSet.Header().Hash) || decoded.PartSetTotal != partSet.Header().Total {
		t.Fatalf("decoded canonical block linkage differs: %+v", decoded)
	}

	dir := t.TempDir()
	writeEvidence(t, dir, "h-plus-one.block", raw)
	reader, err := NewFileEvidenceReader(LocalProvenance{RunID: "r", BindingDigest: strings.Repeat("a", 64), Nodes: map[string]string{"n": dir}}, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	want := Expected{Height: f.height, ChainID: f.chain, BlockID: hex.EncodeToString(f.blockID.Hash), BlockIDPartSetHash: hex.EncodeToString(f.blockID.PartSetHeader.Hash), BlockIDPartSetTotal: f.blockID.PartSetHeader.Total, AppHash: hex.EncodeToString(priorAppHash)}
	linked, digest, err := reader.VerifyHPlusOneLink(context.Background(), "n", want, CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize})
	if err != nil || linked != decoded || digest.SHA256 == "" {
		t.Fatalf("valid saved H+1 link failed: %+v %+v %v", linked, digest, err)
	}
	want.AppHash = strings.Repeat("0", 64)
	if _, _, err := reader.VerifyHPlusOneLink(context.Background(), "n", want, CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize}); err == nil {
		t.Fatal("wrong prior AppHash was accepted")
	}
	want.AppHash = hex.EncodeToString(priorAppHash)
	want.BlockIDPartSetTotal++
	if _, _, err := reader.VerifyHPlusOneLink(context.Background(), "n", want, CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize}); err == nil {
		t.Fatal("wrong previous part-set total was accepted")
	}
}

func TestCometBlockDecoderRejectsTruncatedAndWrongPartSize(t *testing.T) {
	f := makeCometFixture(t, 3)
	raw, _ := makeHPlusOneBlock(t, f, bytes.Repeat([]byte{0x75}, 32))
	decoder := CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize}
	if _, err := decoder.DecodeHPlusOneBlock(context.Background(), raw[:len(raw)-1]); err == nil {
		t.Fatal("truncated block protobuf was accepted")
	}
	correct, err := decoder.DecodeHPlusOneBlock(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	wrong, err := (CometBFT03821BlockDecoder{BlockPartSize: fixturePartSize * 2}).DecodeHPlusOneBlock(context.Background(), raw)
	if err != nil {
		t.Fatal(err)
	}
	if correct.BlockID != wrong.BlockID {
		t.Fatal("canonical block hash changed with part size")
	}
	if correct.PartSetHash == wrong.PartSetHash && correct.PartSetTotal == wrong.PartSetTotal {
		t.Fatal("part-set identity did not reflect the supplied consensus block-part size")
	}
}
