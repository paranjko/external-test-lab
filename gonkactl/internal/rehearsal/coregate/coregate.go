// Package coregate evaluates offline evidence for a synthetic Core recovery.
// It is an acceptance gate, not a recovery implementation or a source repair.
package coregate

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type ArtifactIdentity struct {
	Role, Version, SHA256, ExecutableSHA256, SourceCommit, Runtime string
}

type Expected struct {
	RunID               string
	BindingDigest       string
	RecoveryArtifact    ArtifactIdentity
	StandardArtifact    ArtifactIdentity
	ChainID             string
	Height              int64
	BlockID             string
	BlockIDPartSetHash  string
	BlockIDPartSetTotal uint32
	AppHash             string
	PriorAppHash        string
	ValidatorSetHash    string
	ValidatorCount      int
	ValidatorTotalPower int64
	SeenCommitHash      string
	Nodes               []string
	BarrierStages       []BarrierStage
}

type PersistedState struct {
	Node, Store          string
	RunID, BindingDigest string
	Height               int64
	AppHash, BlockID     string
	HeaderAppHash        string
	BlockIDPartSetHash   string
	BlockIDPartSetTotal  uint32
	LastCommitHeight     int64
	SeenCommitHeight     int64
	SeenCommitHash       string
	SeenCommitBlockID    string
	SeenCommit           []byte
	ValidatorSet         []byte
}

// Readers must read stopped nodes' durable stores. Implementations must not
// answer these calls with RPC status values or caller-provided summaries.
type StoreReader interface {
	ReadApplication(context.Context, string) (PersistedState, error)
	ReadCometState(context.Context, string) (PersistedState, error)
	ReadBlockStore(context.Context, string, int64) (PersistedState, error)
}

// CommitVerifier performs version-matched cryptographic signature and >2/3
// voting-power verification against the complete expected validator set.
type CommitVerifier interface {
	// height is the Commit's own height (H) for a persisted LoadSeenCommit(H),
	// not H-1. H-1 applies to a block's LastCommit when validating the next block.
	VerifySeenCommit(context.Context, string, []byte, []byte, string, string, uint32, int64, string, string) (QuorumProof, error)
}

type QuorumProof struct {
	BlockID, ValidatorSetHash string
	SignedPower, TotalPower   int64
	Signers                   int
}

// BarrierReader waits for a durable height-gated post-state-save sentinel.
// Implementations should verify fsync/receipt authenticity and process stop;
// RPC polling and sleeps do not implement this contract.
type BarrierReader interface {
	VerifyCommitBarriers(context.Context, string, int64, string) ([]BarrierReceipt, error)
}

// ScenarioReader loads immutable harness records for crash boundaries,
// standard-binary handoff and late-node replay from the run's evidence store.
// Qualify never accepts these proof records directly from a CLI caller.
type ScenarioReader interface {
	VerifyCrashBoundaries(context.Context, string, int64) ([]CrashObservation, error)
	VerifyHandoff(context.Context, string, int64) (HandoffProof, error)
	VerifyLateReplay(context.Context, string, int64) (LateReplayProof, error)
}

type BarrierReceipt struct {
	Node, BlockID, ReceiptDigest string
	ChainID, AppHash, Stage      string
	BinaryIdentity               ArtifactIdentity
	BlockIDPartSetHash           string
	BlockIDPartSetTotal          uint32
	RunID, BindingDigest         string
	Height                       int64
	AfterAppCommit               bool
	AfterCometStateSave          bool
	BeforeNextHeightScheduling   bool
	ProcessStopped               bool
}

type BarrierStage string

const (
	HandshakeReplay        BarrierStage = "handshake-replay"
	HandshakeAlreadySynced BarrierStage = "handshake-already-synced"
	ConsensusFinalize      BarrierStage = "consensus-finalize"
)

func fullBarrierStageSet(stages []BarrierStage) bool {
	if len(stages) != 3 {
		return false
	}
	want := map[BarrierStage]bool{HandshakeReplay: true, HandshakeAlreadySynced: true, ConsensusFinalize: true}
	for _, stage := range stages {
		if !want[stage] {
			return false
		}
		delete(want, stage)
	}
	return len(want) == 0
}

type CrashBoundary string

const (
	BeforeAppCommit      CrashBoundary = "before_app_commit"
	AfterAppBeforeState  CrashBoundary = "after_app_before_comet_state"
	AfterStateBeforeNext CrashBoundary = "after_state_before_next_height"
)

type CrashObservation struct {
	Node                        string
	RunID, BindingDigest        string
	BinaryIdentity              ArtifactIdentity
	Boundary                    CrashBoundary
	App, CometState, BlockStore int64
	StartupPath                 string
}

type HandoffProof struct {
	Node                                                                    string
	RunID, BindingDigest                                                    string
	RecoveryIdentity, StandardIdentity                                      ArtifactIdentity
	RecoveryProcessedHeight, StandardStartedHeight, StandardCommittedHeight int64
	HPlusOnePreviousAppHash, HPlusOneBlockID, HPlusOnePartSetHash           string
	HPlusOnePartSetTotal                                                    uint32
	HPlusOneAppHash                                                         string
	OldBinaryReenteredRecoveryBranch                                        bool
}

type LateReplayProof struct {
	Node                                                        string
	RunID, BindingDigest                                        string
	OldBinaryFailedAtDuplicate                                  bool
	RecoveryIdentity                                            ArtifactIdentity
	RecoveryReplayedHeight                                      int64
	ReplayBlockID, ReplayAppHash                                string
	ReplayPartSetHash                                           string
	ReplayPartSetTotal                                          uint32
	HPlusOneBlockID, HPlusOnePartSetHash, HPlusOneHeaderAppHash string
	HPlusOnePartSetTotal                                        uint32
	HPlusOneAppHash                                             string
	NoSigning                                                   bool
	StandardIdentity                                            ArtifactIdentity
	StandardStartedAt, StandardCommittedHeight                  int64
}

type Evidence struct {
	RunID, BindingDigest               string
	RecoveryArtifact, StandardArtifact ArtifactIdentity
}

type Result struct {
	Verdict       contract.Verdict
	Qualification string
	Reasons       []string
	// The product gate never qualifies the correctness of Core repair code.
	CoreRepairQualified bool
	ScopeNote           string
}

const scopeNote = "synthetic persisted-state/replay acceptance only; Core repair source correctness and production recovery remain unqualified"

func identityKey(a ArtifactIdentity) string {
	return strings.Join([]string{a.Role, a.Version, a.SHA256, a.ExecutableSHA256, a.SourceCommit, a.Runtime}, "\x00")
}
func validIdentity(a ArtifactIdentity, role string) bool {
	if a.Role != role || a.Version == "" || !contract.IsDigest(a.SHA256) || !contract.IsDigest(a.ExecutableSHA256) || !validSourceCommit(a.SourceCommit) || a.Runtime == "" {
		return false
	}
	return true
}

func validSourceCommit(value string) bool {
	if len(value) != 40 && len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

// Qualify checks artifact identity, all persisted state stores, barriers,
// crash replay classifications and binary handoff. Empty/missing evidence is
// inconclusive; contradictory evidence fails. No RPC reader is exposed.
func Qualify(ctx context.Context, want Expected, got Evidence, stores StoreReader, commits CommitVerifier, barriers BarrierReader, scenarios ScenarioReader) Result {
	var missing, failures []string
	if stores == nil || commits == nil || barriers == nil || scenarios == nil {
		return Result{Verdict: contract.VerdictBlocked, Qualification: "consistency_checked", Reasons: []string{"required offline store, cryptographic quorum, commit-barrier, or scenario-evidence adapter unavailable"}, ScopeNote: scopeNote}
	}
	if want.RunID == "" || !contract.IsDigest(want.BindingDigest) || !validIdentity(want.RecoveryArtifact, "recovery") || !validIdentity(want.StandardArtifact, "standard") || want.ChainID == "" || want.Height <= 0 || !contract.IsDigest(want.BlockID) || !contract.IsDigest(want.BlockIDPartSetHash) || want.BlockIDPartSetTotal == 0 || !contract.IsDigest(want.AppHash) || !contract.IsDigest(want.PriorAppHash) || !contract.IsDigest(want.ValidatorSetHash) || !contract.IsDigest(want.SeenCommitHash) || want.ValidatorCount <= 0 || want.ValidatorTotalPower <= 0 || len(want.Nodes) == 0 || !fullBarrierStageSet(want.BarrierStages) {
		return Result{Verdict: contract.VerdictBlocked, Reasons: []string{"incomplete qualification expectation"}, ScopeNote: scopeNote}
	}
	if got.RunID != want.RunID || got.BindingDigest != want.BindingDigest {
		failures = append(failures, "run evidence is stale or bound to another run")
	}
	if identityKey(got.RecoveryArtifact) != identityKey(want.RecoveryArtifact) {
		failures = append(failures, "recovery artifact identity mismatch")
	}
	if identityKey(got.StandardArtifact) != identityKey(want.StandardArtifact) {
		failures = append(failures, "standard artifact identity mismatch")
	}
	seen := map[string]bool{}
	for _, n := range want.Nodes {
		if n == "" || seen[n] {
			failures = append(failures, "empty or duplicate node identity")
			continue
		}
		seen[n] = true
		app, e1 := stores.ReadApplication(ctx, n)
		state, e2 := stores.ReadCometState(ctx, n)
		block, e3 := stores.ReadBlockStore(ctx, n, want.Height)
		if e1 != nil || e2 != nil || e3 != nil {
			missing = append(missing, fmt.Sprintf("%s offline store read unavailable", n))
			continue
		}
		if !sameRun(want, app.RunID, app.BindingDigest) || !sameRun(want, state.RunID, state.BindingDigest) || !sameRun(want, block.RunID, block.BindingDigest) {
			failures = append(failures, fmt.Sprintf("%s offline store evidence is stale or bound to another run", n))
			continue
		}
		if app.Node != n || state.Node != n || block.Node != n || app.Store != "application" || state.Store != "comet_state" || block.Store != "blockstore" {
			failures = append(failures, fmt.Sprintf("%s offline reader returned an unexpected node/store", n))
			continue
		}
		if app.Height != want.Height || app.AppHash != want.AppHash || state.Height != want.Height || state.AppHash != want.AppHash || state.BlockID != want.BlockID || state.BlockIDPartSetHash != want.BlockIDPartSetHash || state.BlockIDPartSetTotal != want.BlockIDPartSetTotal || block.Height != want.Height || block.BlockID != want.BlockID || block.BlockIDPartSetHash != want.BlockIDPartSetHash || block.BlockIDPartSetTotal != want.BlockIDPartSetTotal || block.HeaderAppHash != want.PriorAppHash {
			failures = append(failures, fmt.Sprintf("%s persisted app/state/blockstore mismatch", n))
			continue
		}
		if block.SeenCommitHeight != want.Height || block.SeenCommitHash != want.SeenCommitHash || block.SeenCommitBlockID != want.BlockID || len(block.SeenCommit) == 0 || len(block.ValidatorSet) == 0 {
			missing = append(missing, fmt.Sprintf("%s complete seen-commit evidence missing", n))
			continue
		}
		proof, err := commits.VerifySeenCommit(ctx, want.ChainID, block.SeenCommit, block.ValidatorSet, want.BlockID, want.BlockIDPartSetHash, want.BlockIDPartSetTotal, want.Height, want.SeenCommitHash, want.ValidatorSetHash)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s seen-commit cryptographic/quorum verification failed", n))
			continue
		}
		if proof.BlockID != want.BlockID || proof.ValidatorSetHash != want.ValidatorSetHash || proof.TotalPower <= 0 || proof.SignedPower <= 0 || proof.SignedPower > proof.TotalPower || proof.SignedPower <= (proof.TotalPower/3)*2+(proof.TotalPower%3)*2/3 || proof.Signers == 0 {
			failures = append(failures, fmt.Sprintf("%s seen-commit lacks expected >2/3 quorum", n))
		}
	}
	for _, n := range want.Nodes {
		receipts, err := barriers.VerifyCommitBarriers(ctx, n, want.Height, want.BlockID)
		if err != nil {
			missing = append(missing, fmt.Sprintf("%s commit barrier receipt unavailable", n))
			continue
		}
		byStage := map[BarrierStage]BarrierReceipt{}
		for _, r := range receipts {
			stage := BarrierStage(r.Stage)
			if !containsBarrierStage(want.BarrierStages, stage) {
				failures = append(failures, fmt.Sprintf("%s unexpected %s barrier receipt", n, stage))
			}
			if _, ok := byStage[stage]; ok {
				failures = append(failures, fmt.Sprintf("%s duplicate %s barrier receipt", n, stage))
			}
			byStage[stage] = r
		}
		for _, stage := range want.BarrierStages {
			r, ok := byStage[stage]
			if !ok {
				missing = append(missing, fmt.Sprintf("%s %s barrier receipt unavailable", n, stage))
				continue
			}
			if !sameRun(want, r.RunID, r.BindingDigest) || identityKey(r.BinaryIdentity) != identityKey(want.RecoveryArtifact) || r.Node != n || r.ChainID != want.ChainID || r.Height != want.Height || BarrierStage(r.Stage) != stage || r.BlockID != want.BlockID || r.BlockIDPartSetHash != want.BlockIDPartSetHash || r.BlockIDPartSetTotal != want.BlockIDPartSetTotal || r.AppHash != want.AppHash || r.ReceiptDigest == "" || !r.AfterAppCommit || !r.AfterCometStateSave || !r.BeforeNextHeightScheduling || !r.ProcessStopped {
				failures = append(failures, fmt.Sprintf("%s %s barrier receipt does not prove durable stop boundary", n, stage))
			}
		}
	}
	crashes := make([]CrashObservation, 0)
	handoffs := make([]HandoffProof, 0, len(want.Nodes))
	late := make([]LateReplayProof, 0, len(want.Nodes))
	for _, n := range want.Nodes {
		cs, err := scenarios.VerifyCrashBoundaries(ctx, n, want.Height)
		if err != nil {
			missing = append(missing, n+" crash-boundary evidence unavailable")
		} else {
			crashes = append(crashes, cs...)
		}
		h, err := scenarios.VerifyHandoff(ctx, n, want.Height)
		if err != nil {
			missing = append(missing, n+" handoff evidence unavailable")
		} else {
			handoffs = append(handoffs, h)
		}
		l, err := scenarios.VerifyLateReplay(ctx, n, want.Height)
		if err != nil {
			missing = append(missing, n+" late replay evidence unavailable")
		} else {
			late = append(late, l)
		}
	}
	checkCrashProofs(want, crashes, &missing, &failures)
	checkHandoffs(want, handoffs, &missing, &failures)
	checkLate(want, late, &missing, &failures)
	if len(failures) > 0 {
		return Result{Verdict: contract.Fail, Qualification: "consistency_checked", Reasons: failures, ScopeNote: scopeNote}
	}
	if len(missing) > 0 {
		return Result{Verdict: contract.Inconclusive, Qualification: "consistency_checked", Reasons: missing, ScopeNote: scopeNote}
	}
	return Result{Verdict: contract.Pass, Qualification: "consistency_checked", ScopeNote: scopeNote}
}

func containsBarrierStage(stages []BarrierStage, target BarrierStage) bool {
	for _, stage := range stages {
		if stage == target {
			return true
		}
	}
	return false
}

func sameRun(w Expected, runID, binding string) bool {
	return runID == w.RunID && binding == w.BindingDigest
}

func checkCrashProofs(w Expected, observations []CrashObservation, missing, failures *[]string) {
	need := make(map[string]bool, len(w.Nodes)*3)
	for _, node := range w.Nodes {
		for _, boundary := range []CrashBoundary{BeforeAppCommit, AfterAppBeforeState, AfterStateBeforeNext} {
			need[node+"\x00"+string(boundary)] = true
		}
	}
	for _, c := range observations {
		if !sameRun(w, c.RunID, c.BindingDigest) {
			*failures = append(*failures, c.Node+" crash-boundary proof is stale or bound to another run")
			continue
		}
		if identityKey(c.BinaryIdentity) != identityKey(w.RecoveryArtifact) {
			*failures = append(*failures, c.Node+" crash-boundary used the wrong recovery artifact")
			continue
		}
		if c.Node == "" || c.App < 0 || c.CometState < 0 || c.BlockStore < 0 {
			*failures = append(*failures, "invalid crash-boundary observation")
			continue
		}
		switch c.Boundary {
		case BeforeAppCommit:
			if c.App != eHeightMinusOne(w.Height) || c.CometState != eHeightMinusOne(w.Height) || c.BlockStore != w.Height || c.StartupPath != "replay_saved_block_with_recovery_binary" {
				*failures = append(*failures, c.Node+" pre-Commit crash classification mismatch")
			}
		case AfterAppBeforeState:
			if c.App != w.Height || c.CometState != eHeightMinusOne(w.Height) || c.BlockStore != w.Height || c.StartupPath != "replay_saved_finalize_response_without_migration" {
				*failures = append(*failures, c.Node+" app-committed/state-unsaved crash classification mismatch")
			}
		case AfterStateBeforeNext:
			if c.App != w.Height || c.CometState != w.Height || c.BlockStore != w.Height || c.StartupPath != "resume_from_committed_height" {
				*failures = append(*failures, c.Node+" post-state-save crash classification mismatch")
			}
		default:
			*failures = append(*failures, c.Node+" unknown crash boundary")
		}
		key := c.Node + "\x00" + string(c.Boundary)
		if !need[key] {
			*failures = append(*failures, c.Node+" unexpected or duplicate crash-boundary proof")
		} else {
			delete(need, key)
		}
	}
	if len(need) > 0 {
		*missing = append(*missing, "one or more required per-node crash-boundary proofs missing")
	}
}
func eHeightMinusOne(h int64) int64 { return h - 1 }
func checkHandoffs(w Expected, observations []HandoffProof, missing, failures *[]string) {
	by := map[string]HandoffProof{}
	for _, p := range observations {
		if !sameRun(w, p.RunID, p.BindingDigest) {
			*failures = append(*failures, p.Node+" handoff proof is stale or bound to another run")
		}
		if _, exists := by[p.Node]; exists {
			*failures = append(*failures, p.Node+" duplicate handoff proof")
		}
		by[p.Node] = p
	}
	for _, n := range w.Nodes {
		p, ok := by[n]
		if !ok {
			*missing = append(*missing, n+" old-binary handoff proof missing")
			continue
		}
		if identityKey(p.RecoveryIdentity) != identityKey(w.RecoveryArtifact) || identityKey(p.StandardIdentity) != identityKey(w.StandardArtifact) || p.RecoveryProcessedHeight != w.Height || p.StandardStartedHeight != w.Height || p.StandardCommittedHeight != w.Height+1 || p.HPlusOnePreviousAppHash != w.AppHash || !contract.IsDigest(p.HPlusOneBlockID) || !contract.IsDigest(p.HPlusOnePartSetHash) || p.HPlusOnePartSetTotal == 0 || !contract.IsDigest(p.HPlusOneAppHash) || p.OldBinaryReenteredRecoveryBranch {
			*failures = append(*failures, n+" old-binary H+1 handoff mismatch")
		}
	}
}
func checkLate(w Expected, observations []LateReplayProof, missing, failures *[]string) {
	by := map[string]LateReplayProof{}
	for _, p := range observations {
		if !sameRun(w, p.RunID, p.BindingDigest) {
			*failures = append(*failures, p.Node+" late-replay proof is stale or bound to another run")
		}
		if _, exists := by[p.Node]; exists {
			*failures = append(*failures, p.Node+" duplicate late-replay proof")
		}
		by[p.Node] = p
	}
	for _, n := range w.Nodes {
		p, ok := by[n]
		if !ok {
			*missing = append(*missing, n+" late-node replay proof missing")
			continue
		}
		if !p.OldBinaryFailedAtDuplicate || identityKey(p.RecoveryIdentity) != identityKey(w.RecoveryArtifact) || p.RecoveryReplayedHeight != w.Height || p.ReplayBlockID != w.BlockID || p.ReplayPartSetHash != w.BlockIDPartSetHash || p.ReplayPartSetTotal != w.BlockIDPartSetTotal || p.ReplayAppHash != w.AppHash || !p.NoSigning || identityKey(p.StandardIdentity) != identityKey(w.StandardArtifact) || p.StandardStartedAt != w.Height || p.StandardCommittedHeight != w.Height+1 || !contract.IsDigest(p.HPlusOneBlockID) || !contract.IsDigest(p.HPlusOnePartSetHash) || p.HPlusOnePartSetTotal == 0 || p.HPlusOneHeaderAppHash != w.AppHash || !contract.IsDigest(p.HPlusOneAppHash) {
			*failures = append(*failures, n+" late replay or old-binary negative control mismatch")
		}
	}
}
