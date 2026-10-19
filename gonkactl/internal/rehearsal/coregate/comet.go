package coregate

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
)

const maxCometBlockBytes = 64 << 20

// CometCommitVerifier performs v0.38.21 protobuf decoding, exact validator-set
// hash comparison, and CometBFT's full +2/3 commit signature verification.
type CometCommitVerifier struct{}

const (
	maxCometCommitBytes       = 4 << 20
	maxCometValidatorSetBytes = 16 << 20
)

func (CometCommitVerifier) VerifySeenCommit(ctx context.Context, chainID string, commitBytes, validatorBytes []byte, blockHash, partSetHash string, partSetTotal uint32, height int64, seenCommitHash, validatorSetHash string) (QuorumProof, error) {
	if err := ctx.Err(); err != nil {
		return QuorumProof{}, err
	}
	if chainID == "" || height <= 0 || partSetTotal == 0 {
		return QuorumProof{}, errors.New("chain ID, positive commit height and part-set total are required")
	}
	blockHashBytes, err := decodeDigestField("BlockID hash", blockHash)
	if err != nil {
		return QuorumProof{}, err
	}
	partHashBytes, err := decodeDigestField("BlockID part-set hash", partSetHash)
	if err != nil {
		return QuorumProof{}, err
	}
	expectedValidatorHash, err := decodeDigestField("validator-set hash", validatorSetHash)
	if err != nil {
		return QuorumProof{}, err
	}
	if len(commitBytes) == 0 || len(validatorBytes) == 0 {
		return QuorumProof{}, errors.New("raw Comet commit and validator-set protobuf bytes are required")
	}
	if len(commitBytes) > maxCometCommitBytes || len(validatorBytes) > maxCometValidatorSetBytes {
		return QuorumProof{}, errors.New("raw Comet commit or validator-set protobuf exceeds configured safety bound")
	}

	var commitProto cmtproto.Commit
	if err := proto.Unmarshal(commitBytes, &commitProto); err != nil {
		return QuorumProof{}, fmt.Errorf("decode CometBFT v0.38.21 commit protobuf: %w", err)
	}
	commit, err := tmtypes.CommitFromProto(&commitProto)
	if err != nil {
		return QuorumProof{}, fmt.Errorf("convert CometBFT commit: %w", err)
	}
	if commit.Height != height {
		return QuorumProof{}, fmt.Errorf("seen commit height %d does not equal expected H %d", commit.Height, height)
	}
	expectedCommitHash, err := decodeDigestField("seen-commit hash", seenCommitHash)
	if err != nil {
		return QuorumProof{}, err
	}
	if !equalBytes(commit.Hash(), expectedCommitHash) {
		return QuorumProof{}, errors.New("raw seen-commit hash differs from saved inspector value")
	}
	if err := commit.ValidateBasic(); err != nil {
		return QuorumProof{}, fmt.Errorf("invalid CometBFT commit: %w", err)
	}

	var validatorProto cmtproto.ValidatorSet
	if err := proto.Unmarshal(validatorBytes, &validatorProto); err != nil {
		return QuorumProof{}, fmt.Errorf("decode CometBFT v0.38.21 validator-set protobuf: %w", err)
	}
	validatorSet, err := tmtypes.ValidatorSetFromProto(&validatorProto)
	if err != nil {
		return QuorumProof{}, fmt.Errorf("convert CometBFT validator set: %w", err)
	}
	actualValidatorHash := validatorSet.Hash()
	if !equalBytes(actualValidatorHash, expectedValidatorHash) {
		return QuorumProof{}, errors.New("persisted Comet validator-set hash differs from expected hash")
	}

	blockID := tmtypes.BlockID{
		Hash:          blockHashBytes,
		PartSetHeader: tmtypes.PartSetHeader{Total: partSetTotal, Hash: partHashBytes},
	}
	if !commit.BlockID.Equals(blockID) {
		return QuorumProof{}, errors.New("persisted seen commit BlockID differs from expected BlockID")
	}
	// LoadSeenCommit(H) returns the commit for H itself. H-1 is used when a
	// block at H includes the prior commit in Header.LastCommit.
	if err := validatorSet.VerifyCommit(chainID, blockID, height, commit); err != nil {
		return QuorumProof{}, fmt.Errorf("CometBFT commit signature/quorum verification failed: %w", err)
	}

	var signedPower int64
	var signers int
	for _, sig := range commit.Signatures {
		if sig.BlockIDFlag != tmtypes.BlockIDFlagCommit {
			continue
		}
		_, validator := validatorSet.GetByAddress(sig.ValidatorAddress)
		if validator == nil {
			return QuorumProof{}, errors.New("verified commit contains signer absent from validator set")
		}
		signedPower += validator.VotingPower
		signers++
	}
	return QuorumProof{
		BlockID:          blockHash,
		ValidatorSetHash: hex.EncodeToString(actualValidatorHash),
		SignedPower:      signedPower,
		TotalPower:       validatorSet.TotalVotingPower(),
		Signers:          signers,
	}, nil
}

func decodeDigestField(name, value string) ([]byte, error) {
	if !validDigest(value) {
		return nil, fmt.Errorf("%s must be a lowercase SHA-256 digest", name)
	}
	b, err := hex.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("decode %s: %w", name, err)
	}
	return b, nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

// CometBFT03821BlockDecoder decodes the Comet protobuf Block encoding saved by
// the evidence producer. The part size is a consensus/runtime input and must
// match the block's original part-set construction.
type CometBFT03821BlockDecoder struct {
	BlockPartSize uint32
}

func (d CometBFT03821BlockDecoder) DecodeHPlusOneBlock(ctx context.Context, raw []byte) (HPlusOneBlockHeader, error) {
	if err := ctx.Err(); err != nil {
		return HPlusOneBlockHeader{}, err
	}
	if len(raw) == 0 || len(raw) > maxCometBlockBytes {
		return HPlusOneBlockHeader{}, fmt.Errorf("Comet block size must be between 1 and %d bytes", maxCometBlockBytes)
	}
	if d.BlockPartSize == 0 {
		return HPlusOneBlockHeader{}, errors.New("original Comet block part size is required")
	}
	var pb cmtproto.Block
	if err := proto.Unmarshal(raw, &pb); err != nil {
		return HPlusOneBlockHeader{}, fmt.Errorf("decode CometBFT v0.38.21 block protobuf: %w", err)
	}
	block, err := tmtypes.BlockFromProto(&pb)
	if err != nil {
		return HPlusOneBlockHeader{}, fmt.Errorf("convert Comet block: %w", err)
	}
	if err := block.ValidateBasic(); err != nil {
		return HPlusOneBlockHeader{}, fmt.Errorf("invalid Comet block: %w", err)
	}
	canonicalProto, err := block.ToProto()
	if err != nil {
		return HPlusOneBlockHeader{}, fmt.Errorf("canonicalize Comet block: %w", err)
	}
	canonicalBytes, err := proto.Marshal(canonicalProto)
	if err != nil {
		return HPlusOneBlockHeader{}, fmt.Errorf("marshal canonical Comet block: %w", err)
	}
	if !bytes.Equal(canonicalBytes, raw) {
		return HPlusOneBlockHeader{}, errors.New("saved Comet block protobuf is not canonical; part-set identity cannot be reconstructed exactly")
	}
	partSet, err := block.MakePartSet(d.BlockPartSize)
	if err != nil {
		return HPlusOneBlockHeader{}, fmt.Errorf("rebuild Comet block part set: %w", err)
	}
	previous := block.Header.LastBlockID
	return HPlusOneBlockHeader{
		Height:               block.Height,
		ChainID:              block.ChainID,
		BlockID:              hex.EncodeToString(block.Hash()),
		PartSetHash:          hex.EncodeToString(partSet.Header().Hash),
		PartSetTotal:         partSet.Header().Total,
		HeaderAppHash:        hex.EncodeToString(block.AppHash),
		PreviousBlockID:      hex.EncodeToString(previous.Hash),
		PreviousPartSetHash:  hex.EncodeToString(previous.PartSetHeader.Hash),
		PreviousPartSetTotal: previous.PartSetHeader.Total,
	}, nil
}

var _ CommitVerifier = CometCommitVerifier{}
var _ HPlusOneBlockDecoder = CometBFT03821BlockDecoder{}
