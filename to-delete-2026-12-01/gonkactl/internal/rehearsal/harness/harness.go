// Package harness validates run-bound observations from a multi-validator
// recovery rehearsal. It checks library-level trace consistency; it does not
// execute or qualify a node runtime.
package harness

import (
	"errors"
	"fmt"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

type Case string

const (
	OneUpdate        Case = "one-update"
	TwoUpdates       Case = "two-updates"
	DuplicateControl Case = "duplicate-control"
	SameHRepair      Case = "same-h-repair"
	StandardHPlusOne Case = "standard-h-plus-one"
	Restart          Case = "standard-runtime-restart"
	LateCatchup      Case = "late-validator-catchup"
	Lifecycle        Case = "two-full-epochs-poc-rotation"
)

type Event string

const (
	ObservedFailure     Event = "observed-failure"
	RepairApplied       Event = "repair-applied"
	CommitBarrier       Event = "commit-barrier"
	StandardStarted     Event = "standard-started"
	BlockCommitted      Event = "block-committed"
	LateCatchupComplete Event = "late-catchup-complete"
	EpochComplete       Event = "epoch-complete"
	PoCComplete         Event = "poc-complete"
	RotationComplete    Event = "rotation-complete"
	RestartComplete     Event = "restart-complete"
)

// Observation is a typed assertion accompanied by immutable evidence digests.
// Height fields are descriptive and never substitute for the evidence refs.
type Observation struct {
	Sequence             uint64            `json:"sequence"`
	RunID                string            `json:"run_id"`
	BindingDigest        string            `json:"binding_digest"`
	Case                 Case              `json:"case"`
	Event                Event             `json:"event"`
	ValidatorID          string            `json:"validator_id"`
	NodeID               string            `json:"node_id"`
	VotingPower          int64             `json:"voting_power"`
	ValidatorSetHash     string            `json:"validator_set_hash"`
	NextValidatorSetHash string            `json:"next_validator_set_hash,omitempty"`
	AppliedUpdateCount   int               `json:"applied_update_count"`
	EpochIndex           int64             `json:"epoch_index"`
	CatchupFromHeight    int64             `json:"catchup_from_height,omitempty"`
	ReplayMode           string            `json:"replay_mode,omitempty"`
	ReplayEvidenceDigest string            `json:"replay_evidence_digest,omitempty"`
	Height               int64             `json:"height"`
	BlockID              string            `json:"block_id"`
	AppHash              string            `json:"app_hash"`
	ArtifactDigest       string            `json:"artifact_digest"`
	Evidence             map[string]string `json:"evidence_digests"`
	BarrierStageDigests  map[string]string `json:"barrier_stage_digests,omitempty"`
}

type Trace struct {
	Binding      contract.RunBinding `json:"binding"`
	Observations []Observation       `json:"observations"`
}

type Result struct {
	ConsistencyChecked bool          `json:"consistency_checked"`
	RunID              string        `json:"run_id"`
	Cases              map[Case]bool `json:"cases"`
	Reason             string        `json:"reason,omitempty"`
}

var ErrInvalidTrace = errors.New("invalid rehearsal harness trace")

// RequiredEvidence names evidence artifacts that must accompany every event.
// Valid values are SHA-256 hex digests already stored by the owning run.
type Requirements struct {
	Validators              []string
	RecoveryArtifactDigest  string
	StandardArtifactDigest  string
	Height                  int64
	BlockID                 string
	AppHash                 string
	RequiredEvidence        []string
	VerifiedEvidenceDigests map[string]bool
	Cases                   []Case
	ExpectedUpdates         map[Case]int
	Nodes                   []string
	MinimumValidators       int
	MinimumValidatorsByCase map[Case]int
	ValidatorSetHashes      map[int64]string
	FirstLifecycleEpoch     int64
	CatchupHeight           int64
	CatchupBlockID          string
	CatchupAppHash          string
	LaggingValidator        string
	RestartHeight           int64
	RestartBlockID          string
	RestartAppHash          string
}

// ValidateSuite validates distinct case runs and rejects run reuse. This is
// required for controls and update variants so one trace cannot stand in for
// another experimental condition.
func ValidateSuite(traces []Trace, req Requirements) ([]Result, error) {
	if len(traces) != len(req.Cases) || len(traces) == 0 {
		return nil, fmt.Errorf("%w: suite must contain one trace for every requested case", ErrInvalidTrace)
	}
	seenRun, seenCase := map[string]bool{}, map[Case]bool{}
	results := make([]Result, 0, len(traces))
	for _, trace := range traces {
		if seenRun[trace.Binding.RunID] {
			return nil, fmt.Errorf("%w: case runs must have distinct run IDs", ErrInvalidTrace)
		}
		if len(trace.Observations) == 0 {
			return nil, fmt.Errorf("%w: empty case trace", ErrInvalidTrace)
		}
		c := trace.Observations[0].Case
		if seenCase[c] {
			return nil, fmt.Errorf("%w: duplicate case trace %q", ErrInvalidTrace, c)
		}
		one := req
		one.Cases = []Case{c}
		result, err := Validate(trace, one)
		if err != nil {
			return nil, err
		}
		seenRun[trace.Binding.RunID], seenCase[c] = true, true
		results = append(results, result)
	}
	for _, c := range req.Cases {
		if !seenCase[c] {
			return nil, fmt.Errorf("%w: missing case %q", ErrInvalidTrace, c)
		}
	}
	return results, nil
}

var sequences = map[Case][]Event{
	OneUpdate:        {ObservedFailure},
	TwoUpdates:       {ObservedFailure},
	DuplicateControl: {ObservedFailure},
	SameHRepair:      {RepairApplied, CommitBarrier},
	StandardHPlusOne: {StandardStarted, BlockCommitted},
	Restart:          {RestartComplete},
	LateCatchup:      {LateCatchupComplete},
	Lifecycle:        {EpochComplete, PoCComplete, RotationComplete, EpochComplete, PoCComplete, RotationComplete, RestartComplete},
}

var eventEvidence = map[Event]string{
	ObservedFailure:     "negative_control",
	RepairApplied:       "repair",
	CommitBarrier:       "offline_barrier",
	StandardStarted:     "standard_binary",
	BlockCommitted:      "block",
	RestartComplete:     "restart",
	LateCatchupComplete: "late_catchup",
	EpochComplete:       "epoch",
	PoCComplete:         "poc",
	RotationComplete:    "rotation",
}

const validatorSetEvidence = "validator_set"

var requiredBarrierStages = []string{"handshake-replay", "handshake-already-synced", "consensus-finalize"}

// Validate requires one complete, ordered, run-bound event sequence per
// requested case and validator. Each receipt's digest map is checked against
// the binding and sequence. A consistent fixture trace is explicitly not a
// runtime qualification verdict.
func Validate(trace Trace, req Requirements) (Result, error) {
	r := Result{RunID: trace.Binding.RunID, Cases: map[Case]bool{}}
	fail := func(format string, args ...any) (Result, error) {
		r.Reason = fmt.Sprintf(format, args...)
		return r, fmt.Errorf("%w: %s", ErrInvalidTrace, r.Reason)
	}
	if err := contract.ValidateBinding(trace.Binding); err != nil {
		return fail("invalid binding: %v", err)
	}
	bindingDigest, err := contract.Digest(trace.Binding)
	if err != nil {
		return fail("binding digest: %v", err)
	}
	if req.MinimumValidators < 1 {
		req.MinimumValidators = 1
	}
	validators := map[string]bool{}
	for _, v := range req.Validators {
		if v == "" || validators[v] {
			return fail("validator inventory is empty or duplicated")
		}
		validators[v] = true
	}
	nodes := map[string]bool{}
	for _, node := range req.Nodes {
		if node == "" || nodes[node] {
			return fail("node inventory is empty or duplicated")
		}
		nodes[node] = true
	}
	if len(nodes) == 0 {
		return fail("node inventory is required")
	}
	if !contract.IsDigest(req.RecoveryArtifactDigest) || !contract.IsDigest(req.StandardArtifactDigest) {
		return fail("exact recovery and standard artifact digests are required")
	}
	if trace.Binding.RuntimeIdentities["recovery_binary"] != req.RecoveryArtifactDigest || trace.Binding.RuntimeIdentities["standard_binary"] != req.StandardArtifactDigest {
		return fail("run binding does not pin the exact recovery and standard binaries")
	}
	if req.Height <= 0 || req.BlockID == "" || req.AppHash == "" {
		return fail("expected H, BlockID and AppHash are required")
	}
	if trace.Binding.Heights.FirstRepaired != req.Height || trace.Binding.BlockID != req.BlockID || trace.Binding.AppHash != req.AppHash {
		return fail("expected H, BlockID or AppHash differs from immutable run binding")
	}
	if len(req.ValidatorSetHashes) == 0 {
		return fail("verified validator-set hashes are required")
	}
	for _, hash := range req.ValidatorSetHashes {
		if !contract.IsDigest(hash) {
			return fail("invalid expected validator-set hash")
		}
	}
	if len(req.Cases) == 0 || len(req.RequiredEvidence) == 0 {
		return fail("case and evidence requirements are required")
	}
	caseSet := map[Case]bool{}
	for _, c := range req.Cases {
		if _, ok := sequences[c]; !ok || caseSet[c] {
			return fail("unknown or duplicated case %q", c)
		}
		caseSet[c] = true
		minimum := req.MinimumValidators
		if override := req.MinimumValidatorsByCase[c]; override > 0 {
			minimum = override
		}
		if len(validators) < minimum {
			return fail("case %s requires at least %d active validators", c, minimum)
		}
	}
	if caseSet[LateCatchup] && (req.LaggingValidator == "" || !validators[req.LaggingValidator]) {
		return fail("late catchup requires a designated lagging validator")
	}
	if caseSet[Restart] && (req.RestartHeight <= req.Height || req.RestartBlockID == "" || req.RestartAppHash == "") {
		return fail("restart requires an expected post-H block identity")
	}
	evidenceSet := map[string]bool{}
	for _, name := range req.RequiredEvidence {
		if name == "" || evidenceSet[name] {
			return fail("empty or duplicate evidence requirement")
		}
		evidenceSet[name] = true
	}
	byCaseValidator := map[Case]map[string][]Observation{}
	var last uint64
	for _, o := range trace.Observations {
		if o.Sequence == 0 || o.Sequence <= last {
			return fail("observations are stale or out of order")
		}
		last = o.Sequence
		if o.RunID != trace.Binding.RunID || o.BindingDigest != bindingDigest {
			return fail("mixed or stale run binding")
		}
		if !caseSet[o.Case] || !validators[o.ValidatorID] || !nodes[o.NodeID] || o.VotingPower <= 0 {
			return fail("unexpected case or validator")
		}
		if o.Case == LateCatchup && o.ValidatorID != req.LaggingValidator {
			return fail("late catchup observation is not from the designated lagging validator")
		}
		if o.Case == OneUpdate || o.Case == TwoUpdates {
			want := req.ExpectedUpdates[o.Case]
			if want <= 0 || o.AppliedUpdateCount != want {
				return fail("case %s has wrong applied update count", o.Case)
			}
		}
		if expectedSet := req.ValidatorSetHashes[o.EpochIndex]; expectedSet == "" || o.ValidatorSetHash != expectedSet {
			return fail("validator set mismatch at epoch %d", o.EpochIndex)
		}
		if o.Case == Lifecycle && o.Event == RotationComplete {
			nextSet := req.ValidatorSetHashes[o.EpochIndex+1]
			if !contract.IsDigest(nextSet) || o.NextValidatorSetHash != nextSet || nextSet == o.ValidatorSetHash {
				return fail("rotation lacks an expected validator-set transition at epoch %d", o.EpochIndex)
			}
		} else if o.NextValidatorSetHash != "" {
			return fail("unexpected next validator-set claim outside lifecycle rotation")
		}
		wantArtifact := req.RecoveryArtifactDigest
		if o.Case == StandardHPlusOne || o.Case == Restart || o.Case == LateCatchup || o.Case == Lifecycle {
			wantArtifact = req.StandardArtifactDigest
		}
		if o.ArtifactDigest != wantArtifact {
			return fail("wrong artifact for case %s", o.Case)
		}
		if (o.Event == CommitBarrier || o.Event == BlockCommitted) && (o.BlockID != req.BlockID || o.AppHash != req.AppHash) {
			return fail("block identity or app hash mismatch for %s", o.Event)
		}
		if o.Event == CommitBarrier && o.Height != req.Height {
			return fail("unexpected H for %s", o.Event)
		}
		if o.Event == CommitBarrier {
			if len(o.BarrierStageDigests) != len(requiredBarrierStages) {
				return fail("commit barrier does not include all required verified stages")
			}
			for _, stage := range requiredBarrierStages {
				digest := o.BarrierStageDigests[stage]
				if !contract.IsDigest(digest) || !req.VerifiedEvidenceDigests[digest] {
					return fail("missing or unregistered barrier stage %s", stage)
				}
			}
		}
		if o.Event == BlockCommitted && o.Height != req.Height+1 {
			return fail("standard block is not H+1")
		}
		if (o.Case == Restart || o.Case == Lifecycle && o.Event == RestartComplete) && (o.Event != RestartComplete || o.Height != req.RestartHeight || o.BlockID != req.RestartBlockID || o.AppHash != req.RestartAppHash) {
			return fail("restart lacks the expected post-H block observation")
		}
		if o.Case == Lifecycle {
			wantEpoch := req.FirstLifecycleEpoch
			if wantEpoch <= 0 {
				return fail("first lifecycle epoch is required")
			}
			idx := len(byCaseValidator[o.Case][o.ValidatorID])
			if idx >= 3 {
				wantEpoch++
			}
			if o.EpochIndex != wantEpoch {
				return fail("lifecycle epoch sequence is incomplete or out of order")
			}
		}
		if o.Case == LateCatchup && (o.Event != LateCatchupComplete || req.CatchupHeight <= req.Height || o.Height != req.CatchupHeight || o.CatchupFromHeight >= o.Height || o.CatchupFromHeight < req.Height || o.BlockID != req.CatchupBlockID || o.AppHash != req.CatchupAppHash || (o.ReplayMode != "saved-block-replay" && o.ReplayMode != "state-sync") || !contract.IsDigest(o.ReplayEvidenceDigest) || !req.VerifiedEvidenceDigests[o.ReplayEvidenceDigest]) {
			return fail("late catchup lacks a lag interval or common block identity")
		}
		key := fmt.Sprintf("%s/%s/%d", o.Case, o.ValidatorID, o.Sequence)
		requiredEvidence := make(map[string]bool, len(evidenceSet)+1)
		for name := range evidenceSet {
			requiredEvidence[name] = true
		}
		requiredEvidence[validatorSetEvidence] = true
		if name := eventEvidence[o.Event]; name != "" {
			requiredEvidence[name] = true
		}
		for name := range requiredEvidence {
			if !contract.IsDigest(o.Evidence[name]) || !req.VerifiedEvidenceDigests[o.Evidence[name]] {
				return fail("missing or invalid %s evidence for %s", name, key)
			}
		}
		if byCaseValidator[o.Case] == nil {
			byCaseValidator[o.Case] = map[string][]Observation{}
		}
		byCaseValidator[o.Case][o.ValidatorID] = append(byCaseValidator[o.Case][o.ValidatorID], o)
	}
	for c := range caseSet {
		for v := range validators {
			if c == LateCatchup && v != req.LaggingValidator {
				continue
			}
			got := byCaseValidator[c][v]
			want := sequences[c]
			if len(got) != len(want) {
				return fail("case %s validator %s has %d events; want %d", c, v, len(got), len(want))
			}
			for i, event := range want {
				if got[i].Event != event {
					return fail("case %s validator %s event %d is %s; want %s", c, v, i, got[i].Event, event)
				}
			}
		}
		r.Cases[c] = true
	}
	r.ConsistencyChecked = true
	return r, nil
}
