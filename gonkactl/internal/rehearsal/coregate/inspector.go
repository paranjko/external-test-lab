package coregate

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// InspectorSummary is the bounded subset emitted by gonklab-state-inspect.
// It intentionally excludes its `seen_commit_verification` assertion as a
// cryptographic proof: the summary has no raw commit or validator bytes.
type InspectorSummary struct {
	Node, ChainID, ObservedUTC, CopyMarkerKind       string
	ApplicationHeight, CometHeight, BlockstoreHeight int64
	ApplicationHash, CometAppHash, HeaderAppHash     string
	CometBlockHash, BlockIDHash, PartSetHash         string
	PartSetTotal                                     uint32
	SeenCommitHeight                                 int64
	SeenCommitHash                                   string
	SeenCommitBlockIDHash, SeenCommitVerification    string
	SeenCommitSignatures                             int
	SeenCommitVotingPower                            int64
	ValidatorCount                                   int
	ValidatorTotalPower                              int64
	KVCount                                          uint64
	KVSHA256                                         string
}

// ParseInspectorSummary decodes the documented state-inspector JSON shape.
// Unknown fields remain forward-compatible; duplicate keys and malformed
// values are rejected by the protocol's strict JSON decoder.
func ParseInspectorSummary(node string, raw []byte) (InspectorSummary, error) {
	var out InspectorSummary
	if strings.TrimSpace(node) == "" {
		return out, fmt.Errorf("node identity is required")
	}
	var root map[string]json.RawMessage
	if err := contract.DecodeStrict(raw, &root); err != nil {
		return out, fmt.Errorf("decode inspector summary: %w", err)
	}
	if root == nil {
		return out, fmt.Errorf("inspector summary must be an object")
	}
	var marker, app, comet, block map[string]json.RawMessage
	decodeObj := func(key string, dst *map[string]json.RawMessage) error {
		v, ok := root[key]
		if !ok {
			return fmt.Errorf("missing %s", key)
		}
		if err := contract.DecodeStrict(v, dst); err != nil {
			return fmt.Errorf("decode %s: %w", key, err)
		}
		return nil
	}
	if err := decodeObj("copy_marker", &marker); err != nil {
		return out, err
	}
	if err := decodeObj("application", &app); err != nil {
		return out, err
	}
	if err := decodeObj("comet_state", &comet); err != nil {
		return out, err
	}
	if err := decodeObj("blockstore", &block); err != nil {
		return out, err
	}
	var markerKind, observed, kvsha string
	var appHeight, cometHeight, blockHeight, commitHeight int64
	var appHash, cometHash, cometBlock, headerAppHash, blockID, partHash, commitID, commitHash, commitResult string
	var partTotal uint32
	var signatures int
	var validatorCount int
	var votingPower, validatorPower, kvcount uint64
	read := func(fields map[string]json.RawMessage, key string, dst any) error {
		v, ok := fields[key]
		if !ok {
			return fmt.Errorf("missing field %s", key)
		}
		return contract.DecodeStrict(v, dst)
	}
	for _, entry := range []struct {
		fields map[string]json.RawMessage
		key    string
		dst    any
	}{{marker, "kind", &markerKind}, {root, "observed_utc", &observed}, {root, "kv_dump_record_count", &kvcount}, {root, "kv_dump_sha256", &kvsha}, {app, "height", &appHeight}, {app, "app_hash_hex", &appHash}, {comet, "height", &cometHeight}, {comet, "chain_id", &out.ChainID}, {comet, "app_hash_hex", &cometHash}, {comet, "last_block_id_hash_hex", &cometBlock}, {comet, "validator_count", &validatorCount}, {comet, "validator_total_power", &validatorPower}, {block, "height", &blockHeight}, {block, "block_id_hash_hex", &blockID}, {block, "block_id_part_set_hash_hex", &partHash}, {block, "block_id_part_set_total", &partTotal}, {block, "header_app_hash_hex", &headerAppHash}, {block, "seen_commit_height", &commitHeight}, {block, "seen_commit_hash_hex", &commitHash}, {block, "seen_commit_block_id_hash_hex", &commitID}, {block, "seen_commit_verification", &commitResult}, {block, "seen_commit_signatures", &signatures}, {block, "seen_commit_voting_power", &votingPower}} {
		if err := read(entry.fields, entry.key, entry.dst); err != nil {
			return out, err
		}
	}
	out = InspectorSummary{Node: node, ChainID: out.ChainID, ObservedUTC: observed, CopyMarkerKind: markerKind, ApplicationHeight: appHeight, CometHeight: cometHeight, BlockstoreHeight: blockHeight, ApplicationHash: appHash, CometAppHash: cometHash, HeaderAppHash: headerAppHash, CometBlockHash: cometBlock, BlockIDHash: blockID, PartSetHash: partHash, PartSetTotal: partTotal, SeenCommitHeight: commitHeight, SeenCommitHash: commitHash, SeenCommitBlockIDHash: commitID, SeenCommitVerification: commitResult, SeenCommitSignatures: signatures, SeenCommitVotingPower: int64(votingPower), ValidatorCount: validatorCount, ValidatorTotalPower: int64(validatorPower), KVCount: kvcount, KVSHA256: kvsha}
	// Some fields are obtained from top-level metadata and others from nested
	// records; enforce required shape and digest validity without accepting the
	// summary's commit-verification assertion as cryptographic evidence.
	if markerKind != "gnklab-readonly-db-copy-v1" || out.ChainID == "" || out.ObservedUTC == "" || out.ApplicationHeight <= 0 || out.CometHeight <= 0 || out.BlockstoreHeight <= 0 || !contract.IsDigest(out.ApplicationHash) || !contract.IsDigest(out.CometAppHash) || !contract.IsDigest(out.HeaderAppHash) || !contract.IsDigest(out.CometBlockHash) || !contract.IsDigest(out.BlockIDHash) || !contract.IsDigest(out.PartSetHash) || out.PartSetTotal == 0 || out.ValidatorCount <= 0 || out.ValidatorTotalPower <= 0 || out.SeenCommitHeight <= 0 || !contract.IsDigest(out.SeenCommitHash) || out.SeenCommitSignatures <= 0 || out.SeenCommitVotingPower <= 0 || out.SeenCommitVotingPower > out.ValidatorTotalPower || out.KVCount == 0 || !contract.IsDigest(out.KVSHA256) {
		return InspectorSummary{}, fmt.Errorf("inspector summary is incomplete or unsupported")
	}
	return out, nil
}

type SummaryComparison struct {
	Verdict             contract.Verdict
	StateConsistent     bool
	QuorumVerified      bool
	CoreRepairQualified bool
	Reasons             []string
}

// CompareInspectorSummaries checks only machine-readable offline state
// consistency. This evidence format lacks raw seen-commit/validator bytes,
// a signed run binding, barrier receipt, and old-binary lifecycle proofs, so
// it cannot return PASS or qualify Core repair.
func CompareInspectorSummaries(expected Expected, summaries []InspectorSummary) SummaryComparison {
	result := SummaryComparison{Verdict: contract.VerdictBlocked}
	if len(summaries) != len(expected.Nodes) || len(summaries) == 0 {
		result.Reasons = append(result.Reasons, "offline inspector summary is missing for one or more expected nodes")
		return result
	}
	byNode := map[string]InspectorSummary{}
	for _, s := range summaries {
		if _, ok := byNode[s.Node]; ok {
			result.Reasons = append(result.Reasons, "duplicate offline summary for node "+s.Node)
		}
		byNode[s.Node] = s
	}
	var first *InspectorSummary
	for _, node := range expected.Nodes {
		s, ok := byNode[node]
		if !ok {
			result.Reasons = append(result.Reasons, "offline summary missing for node "+node)
			continue
		}
		if s.ChainID != expected.ChainID || s.ApplicationHeight != expected.Height || s.CometHeight != expected.Height || s.BlockstoreHeight != expected.Height || s.ApplicationHash != expected.AppHash || s.CometAppHash != expected.AppHash || s.HeaderAppHash != expected.PriorAppHash || s.CometBlockHash != strings.ToLower(expected.BlockID) || s.BlockIDHash != strings.ToLower(expected.BlockID) || s.PartSetHash != strings.ToLower(expected.BlockIDPartSetHash) || s.PartSetTotal != expected.BlockIDPartSetTotal || s.SeenCommitHeight != expected.Height || s.SeenCommitHash != expected.SeenCommitHash || s.SeenCommitBlockIDHash != strings.ToLower(expected.BlockID) || s.ValidatorCount != expected.ValidatorCount || s.ValidatorTotalPower != expected.ValidatorTotalPower {
			result.Reasons = append(result.Reasons, "persisted height/hash/BlockID mismatch for node "+node)
		}
		if s.SeenCommitVerification != "valid" {
			result.Reasons = append(result.Reasons, "inspector did not report a valid seen commit for node "+node)
		}
		if first == nil {
			copy := s
			first = &copy
		} else if s.ChainID != first.ChainID || s.ApplicationHeight != first.ApplicationHeight || s.CometHeight != first.CometHeight || s.BlockstoreHeight != first.BlockstoreHeight || s.ApplicationHash != first.ApplicationHash || s.CometAppHash != first.CometAppHash || s.HeaderAppHash != first.HeaderAppHash || s.BlockIDHash != first.BlockIDHash || s.PartSetHash != first.PartSetHash || s.PartSetTotal != first.PartSetTotal || s.SeenCommitHash != first.SeenCommitHash || s.ValidatorCount != first.ValidatorCount || s.ValidatorTotalPower != first.ValidatorTotalPower || s.KVCount != first.KVCount || s.KVSHA256 != first.KVSHA256 {
			result.Reasons = append(result.Reasons, "per-node persisted summaries disagree at the same height")
		}
	}
	if len(result.Reasons) == 0 {
		result.StateConsistent = true
		result.Reasons = append(result.Reasons, "state summaries agree, but raw commit/validator bytes and authenticated run-bound lifecycle evidence are unavailable")
	}
	return result
}
