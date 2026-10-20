package coregate

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// BarrierMarker is the actual JSON emitted by the synthetic Comet barrier.
// It is an observation, not a BarrierReceipt: the file has no run signature,
// executable identity, stop observation, or independent persisted-store proof.
type BarrierMarker struct {
	ChainID  string       `json:"chain_id"`
	Height   int64        `json:"height"`
	Stage    BarrierStage `json:"stage"`
	AppHash  string       `json:"app_hash"`
	BlockID  string       `json:"block_id"`
	Hostname string       `json:"hostname"`
	PID      int          `json:"pid"`
}

// BarrierMarkerExpectation must come from the qualified scenario and the
// controller's inspected container identity, not from the marker being read.
type BarrierMarkerExpectation struct {
	ChainID      string
	Height       int64
	Stage        BarrierStage
	AppHash      string
	BlockHash    string
	PartSetTotal uint32
	PartSetHash  string
	Hostname     string
	PID          int
}

var ErrBarrierMarker = errors.New("synthetic barrier marker is malformed or does not match the expected runtime")

// ParseBarrierMarker validates bounded exact-format bytes. The caller must
// independently establish that a fresh marker came from its owned, currently
// running process; hashing these bytes alone does not establish provenance.
func ParseBarrierMarker(raw []byte, want BarrierMarkerExpectation) (BarrierMarker, error) {
	var marker BarrierMarker
	if len(raw) == 0 || len(raw) > 16<<10 || want.ChainID == "" || want.Height <= 0 ||
		!knownBarrierStage(want.Stage) || !contract.IsDigest(want.AppHash) ||
		!contract.IsDigest(want.BlockHash) || !contract.IsDigest(want.PartSetHash) ||
		want.PartSetTotal == 0 || want.Hostname == "" || want.PID <= 0 {
		return marker, ErrBarrierMarker
	}
	if err := contract.DecodeStrict(raw, &marker); err != nil {
		return BarrierMarker{}, fmt.Errorf("%w: %v", ErrBarrierMarker, err)
	}
	// The producer uses fmt.Sprintf("%X/%d:%X", hash, total, partsHash).
	// Match its complete representation, including the part-set; do not accept
	// a hash-only prefix or silently truncate extra delimiters/trailing fields.
	blockID := strings.ToUpper(want.BlockHash) + "/" + strconv.FormatUint(uint64(want.PartSetTotal), 10) + ":" + strings.ToUpper(want.PartSetHash)
	if marker.ChainID != want.ChainID || marker.Height != want.Height || marker.Stage != want.Stage ||
		marker.AppHash != want.AppHash || marker.BlockID != blockID || marker.Hostname != want.Hostname || marker.PID != want.PID {
		return BarrierMarker{}, ErrBarrierMarker
	}
	return marker, nil
}

func knownBarrierStage(stage BarrierStage) bool {
	return stage == HandshakeReplay || stage == HandshakeAlreadySynced || stage == ConsensusFinalize
}
