package coregate

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmtypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

const (
	ProducerManifestSchema      = "gnk-lab-core-producer-evidence/v1"
	ProducerPhaseBeforeRecovery = "before-recovery"
	ProducerCometVersion        = "0.38.21"
)

// ProducerFile binds a logical producer output to its exact bytes. Filenames
// are fixed contract names, not caller-selected paths.
type ProducerFile struct {
	Filename string `json:"filename"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
}

// ProducerManifest is a local producer-to-file correspondence, not an
// authenticated receipt. Callers must compare its run identity with a trusted
// external binding before using the resulting verification as evidence.
// H+1 is deliberately absent: it is produced only by the post-standard phase.
type ProducerManifest struct {
	SchemaVersion          string       `json:"schema_version"`
	Phase                  string       `json:"phase"`
	RunID                  string       `json:"run_id"`
	NodeID                 string       `json:"node_id"`
	ChainID                string       `json:"chain_id"`
	GenesisSHA256          string       `json:"genesis_sha256"`
	RecoveryArtifactSHA256 string       `json:"recovery_artifact_sha256"`
	Height                 int64        `json:"height"`
	BlockID                string       `json:"block_id"`
	PartSetHash            string       `json:"part_set_hash"`
	PartSetTotal           uint32       `json:"part_set_total"`
	HeaderAppHash          string       `json:"header_app_hash"`
	SeenCommitHash         string       `json:"seen_commit_hash"`
	ValidatorSetHash       string       `json:"validator_set_hash"`
	CometVersion           string       `json:"comet_version"`
	Producer               string       `json:"producer"`
	ProducerVersion        string       `json:"producer_version"`
	ProducerSHA256         string       `json:"producer_sha256"`
	ProducerSourceCommit   string       `json:"producer_source_commit"`
	Command                []string     `json:"command"`
	ExitCode               *int         `json:"exit_code"`
	Provenance             string       `json:"provenance"`
	ObservedUTC            string       `json:"observed_utc"`
	ApplicationHeight      int64        `json:"application_height"`
	CometStateHeight       int64        `json:"comet_state_height"`
	BlockstoreHeight       int64        `json:"blockstore_height"`
	ValidatorSetSource     string       `json:"validator_set_source"`
	ValidatorSetHeight     int64        `json:"validator_set_height"`
	SeenCommit             ProducerFile `json:"seen_commit"`
	ValidatorSet           ProducerFile `json:"validator_set"`
	BlockH                 ProducerFile `json:"block_h"`
}

// ProducerExpectation must be derived independently from the trusted run
// binding and scenario, never from ProducerManifest itself.
type ProducerExpectation struct {
	RunID                  string `json:"run_id"`
	NodeID                 string `json:"node_id"`
	ChainID                string `json:"chain_id"`
	GenesisSHA256          string `json:"genesis_sha256"`
	RecoveryArtifactSHA256 string `json:"recovery_artifact_sha256"`
	ProducerSHA256         string `json:"producer_sha256"`
	Height                 int64  `json:"height"`
	ApplicationHeight      int64  `json:"application_height"`
	CometStateHeight       int64  `json:"comet_state_height"`
	BlockstoreHeight       int64  `json:"blockstore_height"`
	BlockID                string `json:"block_id"`
	PartSetHash            string `json:"part_set_hash"`
	PartSetTotal           uint32 `json:"part_set_total"`
	HeaderAppHash          string `json:"header_app_hash"`
	SeenCommitHash         string `json:"seen_commit_hash"`
	ValidatorSetHash       string `json:"validator_set_hash"`
	ValidatorSetSource     string `json:"validator_set_source"`
	ValidatorSetHeight     int64  `json:"validator_set_height"`
	BlockPartSize          uint32 `json:"block_part_size"`
}

type ProducerVerification struct {
	ManifestSHA256 string              `json:"manifest_sha256"`
	SeenCommit     ProducerFile        `json:"seen_commit"`
	ValidatorSet   ProducerFile        `json:"validator_set"`
	BlockH         ProducerFile        `json:"block_h"`
	Block          HPlusOneBlockHeader `json:"block"`
	Quorum         QuorumProof         `json:"quorum"`
	Boundary       string              `json:"evidence_boundary"`
}

var ErrProducerContract = errors.New("producer evidence contract invalid or mismatched")

// VerifyProducerEvidence verifies exact producer pins, the complete raw
// Commit and matching ValidatorSet at H, and the canonical serialized Block H
// identity. It does not require H+1 and does not authenticate the producer's
// stated provenance or run binding.
func VerifyProducerEvidence(ctx context.Context, manifestRaw, commitRaw, validatorSetRaw, blockHRaw []byte, want ProducerExpectation) (ProducerVerification, error) {
	var out ProducerVerification
	if ctx == nil {
		return out, fmt.Errorf("%w: context is nil", ErrProducerContract)
	}
	if err := ctx.Err(); err != nil {
		return out, err
	}
	var manifest ProducerManifest
	if len(manifestRaw) == 0 || len(manifestRaw) > 1<<20 || contract.DecodeStrict(manifestRaw, &manifest) != nil {
		return out, fmt.Errorf("%w: manifest is missing, oversized, malformed, or contains unsupported fields", ErrProducerContract)
	}
	if err := validateProducerExpectation(want); err != nil {
		return out, err
	}
	if manifest.SchemaVersion != ProducerManifestSchema || manifest.Phase != ProducerPhaseBeforeRecovery ||
		manifest.RunID != want.RunID || manifest.NodeID != want.NodeID || manifest.ChainID != want.ChainID ||
		manifest.GenesisSHA256 != want.GenesisSHA256 || manifest.RecoveryArtifactSHA256 != want.RecoveryArtifactSHA256 ||
		manifest.ProducerSHA256 != want.ProducerSHA256 ||
		manifest.Height != want.Height || manifest.BlockID != want.BlockID || manifest.PartSetHash != want.PartSetHash ||
		manifest.PartSetTotal != want.PartSetTotal || manifest.HeaderAppHash != want.HeaderAppHash ||
		manifest.SeenCommitHash != want.SeenCommitHash || manifest.ValidatorSetHash != want.ValidatorSetHash ||
		manifest.CometVersion != ProducerCometVersion || strings.TrimSpace(manifest.Producer) == "" || strings.TrimSpace(manifest.ProducerVersion) == "" ||
		!validDigest(manifest.ProducerSHA256) || len(manifest.Command) == 0 || manifest.ExitCode == nil || *manifest.ExitCode != 0 ||
		manifest.ApplicationHeight != want.ApplicationHeight || manifest.CometStateHeight != want.CometStateHeight || manifest.BlockstoreHeight != want.BlockstoreHeight ||
		manifest.ValidatorSetSource != want.ValidatorSetSource || (manifest.ValidatorSetSource != "validators" && manifest.ValidatorSetSource != "last_validators") ||
		manifest.ValidatorSetHeight != want.Height || want.ValidatorSetHeight != want.Height ||
		!validSourceCommit(manifest.ProducerSourceCommit) || strings.TrimSpace(manifest.Provenance) == "" || !validObservedUTC(manifest.ObservedUTC) {
		return out, fmt.Errorf("%w: manifest binding or producer metadata differs from expected", ErrProducerContract)
	}
	for _, arg := range manifest.Command {
		if strings.TrimSpace(arg) == "" {
			return out, fmt.Errorf("%w: producer command contains an empty argument", ErrProducerContract)
		}
	}
	if err := verifyProducerFile(manifest.SeenCommit, "seen_commit.bin", commitRaw, maxCometCommitBytes); err != nil {
		return out, err
	}
	if err := verifyProducerFile(manifest.ValidatorSet, "validator_set.bin", validatorSetRaw, maxCometValidatorSetBytes); err != nil {
		return out, err
	}
	if err := verifyProducerFile(manifest.BlockH, "block-h.bin", blockHRaw, maxCometBlockBytes); err != nil {
		return out, err
	}

	quorum, err := (CometCommitVerifier{}).VerifySeenCommit(ctx, want.ChainID, commitRaw, validatorSetRaw,
		want.BlockID, want.PartSetHash, want.PartSetTotal, want.Height, want.SeenCommitHash, want.ValidatorSetHash)
	if err != nil {
		return out, fmt.Errorf("verify saved Comet commit at H: %w", err)
	}
	block, err := (CometBFT03821BlockDecoder{BlockPartSize: want.BlockPartSize}).DecodeHPlusOneBlock(ctx, blockHRaw)
	if err != nil {
		return out, fmt.Errorf("decode canonical Block H: %w", err)
	}
	if block.Height != want.Height || block.ChainID != want.ChainID || block.BlockID != want.BlockID ||
		block.PartSetHash != want.PartSetHash || block.PartSetTotal != want.PartSetTotal || block.HeaderAppHash != want.HeaderAppHash {
		return out, fmt.Errorf("%w: canonical Block H identity differs from trusted expectation", ErrProducerContract)
	}
	var blockProto cmtproto.Block
	if err := proto.Unmarshal(blockHRaw, &blockProto); err != nil {
		return out, fmt.Errorf("decode Block H validator-set linkage: %w", err)
	}
	decodedBlock, err := tmtypes.BlockFromProto(&blockProto)
	if err != nil {
		return out, fmt.Errorf("convert Block H validator-set linkage: %w", err)
	}
	matchedSetHash, err := hex.DecodeString(quorum.ValidatorSetHash)
	if err != nil || !bytes.Equal(decodedBlock.Header.ValidatorsHash, matchedSetHash) {
		return out, fmt.Errorf("%w: Block H ValidatorsHash differs from the cryptographically matched validator set", ErrProducerContract)
	}
	manifestDigest := sha256.Sum256(manifestRaw)
	return ProducerVerification{
		ManifestSHA256: hex.EncodeToString(manifestDigest[:]),
		SeenCommit:     manifest.SeenCommit,
		ValidatorSet:   manifest.ValidatorSet,
		BlockH:         manifest.BlockH,
		Block:          block,
		Quorum:         quorum,
		Boundary:       "local producer/file correspondence only; provenance and run binding are unauthenticated",
	}, nil
}

func validateProducerExpectation(want ProducerExpectation) error {
	if strings.TrimSpace(want.RunID) == "" || strings.TrimSpace(want.NodeID) == "" || strings.TrimSpace(want.ChainID) == "" || want.Height <= 0 || want.BlockPartSize == 0 ||
		want.ApplicationHeight != want.Height-1 || want.CometStateHeight != want.Height-1 || want.BlockstoreHeight != want.Height ||
		!validDigest(want.GenesisSHA256) || !validDigest(want.RecoveryArtifactSHA256) || !validDigest(want.BlockID) ||
		!validDigest(want.ProducerSHA256) ||
		!validDigest(want.PartSetHash) || want.PartSetTotal == 0 || !validDigest(want.HeaderAppHash) ||
		!validDigest(want.SeenCommitHash) || !validDigest(want.ValidatorSetHash) || want.ValidatorSetHeight != want.Height ||
		(want.ValidatorSetSource != "validators" && want.ValidatorSetSource != "last_validators") {
		return fmt.Errorf("%w: independent expectation is incomplete", ErrProducerContract)
	}
	return nil
}

func validObservedUTC(value string) bool {
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return false
	}
	_, offset := parsed.Zone()
	return offset == 0
}

func verifyProducerFile(file ProducerFile, filename string, raw []byte, maxBytes int) error {
	if file.Filename != filename || file.Size <= 0 || file.Size != int64(len(raw)) || len(raw) == 0 || len(raw) > maxBytes || !validDigest(file.SHA256) {
		return fmt.Errorf("%w: %s file name, size, or digest declaration is invalid", ErrProducerContract, filename)
	}
	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != file.SHA256 {
		return fmt.Errorf("%w: %s bytes differ from manifest digest", ErrProducerContract, filename)
	}
	return nil
}

type HPlusOneExpectation struct {
	RunID                string `json:"run_id"`
	NodeID               string `json:"node_id"`
	ChainID              string `json:"chain_id"`
	Height               int64  `json:"height"`
	PreviousBlockID      string `json:"previous_block_id"`
	PreviousPartSetHash  string `json:"previous_part_set_hash"`
	PreviousPartSetTotal uint32 `json:"previous_part_set_total"`
	HeaderAppHash        string `json:"header_app_hash"`
	// The H+1 identity is unknown before launch. Supply all three fields only
	// when checking an already observed, pinned block.
	BlockID      string `json:"block_id"`
	PartSetHash  string `json:"part_set_hash"`
	PartSetTotal uint32 `json:"part_set_total"`
}

type HPlusOneVerification struct {
	Block  HPlusOneBlockHeader `json:"block"`
	SHA256 string              `json:"sha256"`
	Size   int64               `json:"size"`
	Phase  string              `json:"phase"`
}

// Validate binds continuity to recovered H without requiring a future block.
func (want HPlusOneExpectation) Validate() error {
	if strings.TrimSpace(want.RunID) == "" || strings.TrimSpace(want.NodeID) == "" ||
		strings.TrimSpace(want.ChainID) == "" || want.Height <= 0 || want.Height == int64(^uint64(0)>>1) ||
		!validDigest(want.PreviousBlockID) || !validDigest(want.PreviousPartSetHash) ||
		want.PreviousPartSetTotal == 0 || !validDigest(want.HeaderAppHash) {
		return fmt.Errorf("%w: recovered H continuity expectation is incomplete", ErrProducerContract)
	}
	if want.BlockID != "" || want.PartSetHash != "" || want.PartSetTotal != 0 {
		if !validDigest(want.BlockID) || !validDigest(want.PartSetHash) || want.PartSetTotal == 0 {
			return fmt.Errorf("%w: observed H+1 identity must be complete or absent", ErrProducerContract)
		}
	}
	return nil
}

// VerifyPostStandardHPlusOne independently verifies a saved H+1 block after
// standard-binary startup. It is intentionally separate from pre-recovery H
// evidence and cannot gate VerifyProducerEvidence.
func VerifyPostStandardHPlusOne(ctx context.Context, raw []byte, decoder HPlusOneBlockDecoder, want HPlusOneExpectation) (HPlusOneVerification, error) {
	var out HPlusOneVerification
	if ctx == nil {
		return out, fmt.Errorf("%w: context is nil", ErrProducerContract)
	}
	if err := ctx.Err(); err != nil {
		return out, err
	}
	if decoder == nil || len(raw) == 0 || len(raw) > maxCometBlockBytes || want.Validate() != nil {
		return out, fmt.Errorf("%w: post-standard H+1 expectation or bytes are incomplete", ErrProducerContract)
	}
	block, err := decoder.DecodeHPlusOneBlock(ctx, raw)
	if err != nil {
		return out, fmt.Errorf("decode post-standard H+1 block: %w", err)
	}
	if block.Height != want.Height+1 || block.ChainID != want.ChainID || block.PreviousBlockID != want.PreviousBlockID ||
		block.PreviousPartSetHash != want.PreviousPartSetHash || block.PreviousPartSetTotal != want.PreviousPartSetTotal ||
		block.HeaderAppHash != want.HeaderAppHash || !validDigest(block.BlockID) || !validDigest(block.PartSetHash) || block.PartSetTotal == 0 {
		return out, fmt.Errorf("%w: post-standard H+1 block does not link to H expectation", ErrProducerContract)
	}
	if want.BlockID != "" && (block.BlockID != want.BlockID || block.PartSetHash != want.PartSetHash || block.PartSetTotal != want.PartSetTotal) {
		return out, fmt.Errorf("%w: post-standard H+1 block differs from pinned identity", ErrProducerContract)
	}
	sum := sha256.Sum256(raw)
	return HPlusOneVerification{Block: block, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(raw)), Phase: "post-standard"}, nil
}
