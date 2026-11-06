package coregate

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ErrEvidenceUnavailable means the requested source bytes are not present.
// Callers must report this as blocked/inconclusive evidence, never fill it from
// inspector assertions or prose.
var ErrEvidenceUnavailable = errors.New("coregate evidence unavailable")

// LocalProvenance is an operator-supplied mapping from saved source files to a
// rehearsal context. It is deliberately not an authenticated run receipt.
type LocalProvenance struct {
	RunID         string
	BindingDigest string
	Nodes         map[string]string            // node ID -> directory containing saved evidence
	SourceDigests map[string]map[string]string // optional locally recorded byte pins; not authenticated
}

type Limits struct {
	InspectorJSON int64
	AppKVDump     int64
	BarrierJSON   int64
	ScenarioJSON  int64
	RawCommit     int64
	ValidatorSet  int64
	BlockBytes    int64
}

func (l Limits) withDefaults() Limits {
	if l.InspectorJSON <= 0 {
		l.InspectorJSON = 4 << 20
	}
	if l.AppKVDump <= 0 {
		l.AppKVDump = 1 << 30
	}
	if l.BarrierJSON <= 0 {
		l.BarrierJSON = 1 << 20
	}
	if l.ScenarioJSON <= 0 {
		l.ScenarioJSON = 4 << 20
	}
	if l.RawCommit <= 0 {
		l.RawCommit = 4 << 20
	}
	if l.ValidatorSet <= 0 {
		l.ValidatorSet = 16 << 20
	}
	if l.BlockBytes <= 0 {
		l.BlockBytes = 64 << 20
	}
	return l
}

// FileEvidenceReader reads only regular files below explicit node directories.
// It implements the coregate readers but does not authenticate local mappings.
type FileEvidenceReader struct {
	provenance LocalProvenance
	limits     Limits
}

type SourceDigest struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// HPlusOneBlockHeader is the minimal linkage extracted by a version-matched
// Comet block decoder. BlockID must be the canonical block hash computed from
// the decoded header; the coregate package does not implement that algorithm.
type HPlusOneBlockHeader struct {
	Height               int64
	ChainID              string
	BlockID              string
	PartSetHash          string
	PartSetTotal         uint32
	HeaderAppHash        string
	PreviousBlockID      string
	PreviousPartSetHash  string
	PreviousPartSetTotal uint32
}

// HPlusOneBlockDecoder must decode the actual saved Core block encoding and
// derive its canonical BlockID using the producing CometBFT version.
type HPlusOneBlockDecoder interface {
	DecodeHPlusOneBlock(context.Context, []byte) (HPlusOneBlockHeader, error)
}

// NewFileEvidenceReader rejects ambiguous or incomplete local mappings.
func NewFileEvidenceReader(p LocalProvenance, limits Limits) (*FileEvidenceReader, error) {
	if strings.TrimSpace(p.RunID) == "" || !validDigest(p.BindingDigest) || len(p.Nodes) == 0 {
		return nil, fmt.Errorf("local evidence mapping requires run ID, binding digest, and node directories")
	}
	clean := make(map[string]string, len(p.Nodes))
	for node, dir := range p.Nodes {
		if strings.TrimSpace(node) == "" || !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
			return nil, fmt.Errorf("node %q requires a clean absolute evidence directory", node)
		}
		info, err := os.Stat(dir)
		if err != nil || !info.IsDir() {
			return nil, fmt.Errorf("node %q evidence directory unavailable", node)
		}
		clean[node] = dir
	}
	return &FileEvidenceReader{provenance: LocalProvenance{RunID: p.RunID, BindingDigest: p.BindingDigest, Nodes: clean, SourceDigests: p.SourceDigests}, limits: limits.withDefaults()}, nil
}

func validDigest(v string) bool {
	if len(v) != 64 {
		return false
	}
	_, err := hex.DecodeString(v)
	return err == nil && strings.ToLower(v) == v
}

func (r *FileEvidenceReader) read(node, name string, limit int64) ([]byte, SourceDigest, error) {
	dir, ok := r.provenance.Nodes[node]
	if !ok {
		return nil, SourceDigest{}, fmt.Errorf("%w: unknown node %q", ErrEvidenceUnavailable, node)
	}
	path := filepath.Join(dir, name)
	info, err := os.Lstat(path)
	if err != nil {
		return nil, SourceDigest{}, fmt.Errorf("%w: %s: %v", ErrEvidenceUnavailable, name, err)
	}
	if !info.Mode().IsRegular() {
		return nil, SourceDigest{}, fmt.Errorf("%s must be a regular file", name)
	}
	if info.Size() > limit {
		return nil, SourceDigest{}, fmt.Errorf("%s exceeds %d byte limit", name, limit)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, SourceDigest{}, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, SourceDigest{}, err
	}
	if int64(len(b)) > limit {
		return nil, SourceDigest{}, fmt.Errorf("%s exceeds %d byte limit", name, limit)
	}
	sum := sha256.Sum256(b)
	digest := hex.EncodeToString(sum[:])
	if expected := r.provenance.SourceDigests[node][name]; expected != "" && (!validDigest(expected) || expected != digest) {
		return nil, SourceDigest{}, fmt.Errorf("%s digest differs from local source mapping", name)
	}
	return b, SourceDigest{Path: path, Size: int64(len(b)), SHA256: digest}, nil
}

// ReadInspector loads the exact saved inspector bytes and records their digest.
func (r *FileEvidenceReader) ReadInspector(node string) (InspectorSummary, []byte, SourceDigest, error) {
	raw, digest, err := r.read(node, "inspector.json", r.limits.InspectorJSON)
	if err != nil {
		return InspectorSummary{}, nil, SourceDigest{}, err
	}
	summary, err := ParseInspectorSummary(node, raw)
	if err != nil {
		return InspectorSummary{}, nil, SourceDigest{}, err
	}
	return summary, raw, digest, nil
}

func (r *FileEvidenceReader) summaryState(node, store string) (PersistedState, error) {
	s, _, _, err := r.ReadInspector(node)
	if err != nil {
		return PersistedState{}, err
	}
	state := PersistedState{Node: node, Store: store, RunID: r.provenance.RunID, BindingDigest: r.provenance.BindingDigest}
	switch store {
	case "application":
		state.Height, state.AppHash = s.ApplicationHeight, s.ApplicationHash
	case "comet_state":
		state.Height, state.AppHash, state.BlockID = s.CometHeight, s.CometAppHash, s.CometBlockHash
	case "blockstore":
		state.Height, state.BlockID, state.BlockIDPartSetHash, state.BlockIDPartSetTotal = s.BlockstoreHeight, s.BlockIDHash, s.PartSetHash, s.PartSetTotal
		state.HeaderAppHash = s.HeaderAppHash
		state.SeenCommitHeight, state.SeenCommitHash, state.SeenCommitBlockID = s.SeenCommitHeight, s.SeenCommitHash, s.SeenCommitBlockIDHash
	default:
		return PersistedState{}, fmt.Errorf("unsupported store %q", store)
	}
	return state, nil
}

func (r *FileEvidenceReader) ReadApplication(_ context.Context, node string) (PersistedState, error) {
	return r.summaryState(node, "application")
}
func (r *FileEvidenceReader) ReadCometState(_ context.Context, node string) (PersistedState, error) {
	return r.summaryState(node, "comet_state")
}
func (r *FileEvidenceReader) ReadBlockStore(_ context.Context, node string, height int64) (PersistedState, error) {
	s, err := r.summaryState(node, "blockstore")
	if err != nil {
		return PersistedState{}, err
	}
	if height != s.Height {
		return PersistedState{}, fmt.Errorf("requested block height %d differs from saved inspector height %d", height, s.Height)
	}
	commit, _, validators, _, commitErr, validatorErr := r.ReadRawStoreEvidence(node)
	if commitErr != nil || validatorErr != nil {
		return PersistedState{}, fmt.Errorf("%w: %s raw seen-commit bytes and %s complete validator-set bytes are required (inspector claims are not cryptographic proof)", ErrEvidenceUnavailable, missingFile(commitErr), missingFile(validatorErr))
	}
	s.SeenCommit, s.ValidatorSet = append([]byte(nil), commit...), append([]byte(nil), validators...)
	return s, nil
}

// ReadRawStoreEvidence returns the exact persisted proof bytes and independent
// digests. It does not parse or verify the chain-specific encodings.
func (r *FileEvidenceReader) ReadRawStoreEvidence(node string) (commit []byte, commitDigest SourceDigest, validators []byte, validatorDigest SourceDigest, commitErr, validatorErr error) {
	commit, commitDigest, commitErr = r.read(node, "seen_commit.bin", r.limits.RawCommit)
	validators, validatorDigest, validatorErr = r.read(node, "validator_set.bin", r.limits.ValidatorSet)
	return
}

func missingFile(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// ReadHPlusOneBlock returns opaque saved block bytes and their exact digest.
// The bytes can be inspected by a version-matched decoder; this method makes
// no claim about header linkage or commit validity.
func (r *FileEvidenceReader) ReadHPlusOneBlock(node string) ([]byte, SourceDigest, error) {
	b, d, err := r.read(node, "h-plus-one.block", r.limits.BlockBytes)
	if err != nil {
		return nil, SourceDigest{}, err
	}
	if len(b) == 0 {
		return nil, SourceDigest{}, fmt.Errorf("H+1 block bytes are empty")
	}
	return b, d, nil
}

// VerifyHPlusOneLink combines bounded exact-byte reading with decoded linkage
// checks. It is not a signature verifier; callers must supply the decoder
// matching the Core artifact's CometBFT version.
func (r *FileEvidenceReader) VerifyHPlusOneLink(ctx context.Context, node string, want Expected, decoder HPlusOneBlockDecoder) (HPlusOneBlockHeader, SourceDigest, error) {
	if decoder == nil {
		return HPlusOneBlockHeader{}, SourceDigest{}, fmt.Errorf("version-matched H+1 block decoder is required")
	}
	raw, digest, err := r.ReadHPlusOneBlock(node)
	if err != nil {
		return HPlusOneBlockHeader{}, SourceDigest{}, err
	}
	block, err := decoder.DecodeHPlusOneBlock(ctx, raw)
	if err != nil {
		return HPlusOneBlockHeader{}, SourceDigest{}, fmt.Errorf("decode saved H+1 block: %w", err)
	}
	if block.Height != want.Height+1 || block.ChainID != want.ChainID || block.HeaderAppHash != want.AppHash || block.PreviousBlockID != want.BlockID || block.PreviousPartSetHash != want.BlockIDPartSetHash || block.PreviousPartSetTotal != want.BlockIDPartSetTotal || !validDigest(block.BlockID) || !validDigest(block.PartSetHash) || block.PartSetTotal == 0 {
		return HPlusOneBlockHeader{}, SourceDigest{}, fmt.Errorf("saved H+1 block does not link to expected H state")
	}
	return block, digest, nil
}

// ReadBarrierJSON preserves bounded barrier JSON for diagnostics and reports
// its bytes, but intentionally does not interpret it as an authenticated
// BarrierReceipt. Use VerifyCommitBarriers for qualification.
func (r *FileEvidenceReader) ReadBarrierJSON(node string) ([]byte, SourceDigest, error) {
	return r.read(node, "barriers.json", r.limits.BarrierJSON)
}

// JSON barrier/scenario records are not accepted as authenticated receipts.
// The current persisted rehearsal material has no signed machine records to
// verify; exposing assertions here could allow a local file to qualify PASS.
func (r *FileEvidenceReader) VerifyCommitBarriers(context.Context, string, int64, string) ([]BarrierReceipt, error) {
	return nil, fmt.Errorf("%w: authenticated commit-barrier receipts are unavailable; local JSON/digests do not establish receipt authenticity", ErrEvidenceUnavailable)
}
func (r *FileEvidenceReader) VerifyCrashBoundaries(context.Context, string, int64) ([]CrashObservation, error) {
	return nil, fmt.Errorf("%w: machine crash-boundary records are unavailable", ErrEvidenceUnavailable)
}
func (r *FileEvidenceReader) VerifyHandoff(context.Context, string, int64) (HandoffProof, error) {
	return HandoffProof{}, fmt.Errorf("%w: authenticated standard-binary handoff record is unavailable", ErrEvidenceUnavailable)
}
func (r *FileEvidenceReader) VerifyLateReplay(context.Context, string, int64) (LateReplayProof, error) {
	return LateReplayProof{}, fmt.Errorf("%w: authenticated late-replay record is unavailable", ErrEvidenceUnavailable)
}

var _ StoreReader = (*FileEvidenceReader)(nil)
var _ BarrierReader = (*FileEvidenceReader)(nil)
var _ ScenarioReader = (*FileEvidenceReader)(nil)
