package harness

import (
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func testBinding(run string) contract.RunBinding {
	h := int64(10)
	return contract.RunBinding{SchemaVersion: contract.Version, RunID: run, Scenario: contract.Scenario, Workspace: "/tmp/run", OwnershipMarker: "owner", ChainID: "test", GenesisSHA256: strings.Repeat("a", 64), Heights: contract.Heights{Blockstore: 10, App: 9, Consensus: &h, FirstRepaired: 10}, BlockID: "block-H", AppHash: "app-H", AppHashHeight: 9, ToolVersion: "test", CatalogVersion: "1", InputDigests: map[string]string{"source": strings.Repeat("b", 64)}, RuntimeIdentities: map[string]string{"binary": strings.Repeat("c", 64)}, Paths: map[string]string{"source": "/tmp/run/source"}}
}

func testTrace(c Case, run string) Trace {
	b := testBinding(run)
	artifact := strings.Repeat("d", 64)
	if c == StandardHPlusOne || c == Restart || c == LateCatchup || c == Lifecycle {
		artifact = strings.Repeat("e", 64)
	}
	b.RuntimeIdentities["recovery_binary"], b.RuntimeIdentities["standard_binary"] = strings.Repeat("d", 64), strings.Repeat("e", 64)
	d, _ := contract.Digest(b)
	obs := []Observation{}
	seq := uint64(0)
	validators := []string{"v1", "v2"}
	if c == LateCatchup {
		validators = []string{"v2"}
	}
	for _, v := range validators {
		for _, event := range sequences[c] {
			seq++
			height := int64(10)
			if event == BlockCommitted {
				height++
			}
			epoch := int64(1)
			if c == Lifecycle && len(obsForValidator(obs, v)) >= 3 {
				epoch = 2
			}
			if c == LateCatchup {
				epoch = 3
			}
			fromHeight := int64(504)
			if c == LateCatchup {
				height = 515
			}
			digest := strings.Repeat("f", 64)
			validatorSetHash := strings.Repeat("9", 64)
			if epoch == 2 {
				validatorSetHash = strings.Repeat("8", 64)
			} else if epoch == 3 {
				validatorSetHash = strings.Repeat("7", 64)
			}
			evidence := map[string]string{"receipt": digest}
			for _, category := range []string{"validator_set", "negative_control", "repair", "offline_barrier", "standard_binary", "block", "restart", "late_catchup", "epoch", "poc", "rotation"} {
				evidence[category] = digest
			}
			o := Observation{Sequence: seq, RunID: run, BindingDigest: d, Case: c, Event: event, ValidatorID: v, NodeID: "node-" + v, VotingPower: 10, ValidatorSetHash: validatorSetHash, EpochIndex: epoch, Height: height, CatchupFromHeight: fromHeight, ReplayMode: "saved-block-replay", ReplayEvidenceDigest: digest, ArtifactDigest: artifact, Evidence: evidence}
			if c == Lifecycle && event == RotationComplete {
				o.NextValidatorSetHash = strings.Repeat("8", 64)
				if epoch == 2 {
					o.NextValidatorSetHash = strings.Repeat("7", 64)
				}
			}
			if c == OneUpdate {
				o.AppliedUpdateCount = 1
			}
			if c == TwoUpdates {
				o.AppliedUpdateCount = 2
			}
			if event == CommitBarrier {
				o.BarrierStageDigests = map[string]string{"handshake-replay": digest, "handshake-already-synced": digest, "consensus-finalize": digest}
			}
			if event == CommitBarrier || event == BlockCommitted {
				o.BlockID, o.AppHash = "block-H", "app-H"
			}
			if event == LateCatchupComplete {
				o.BlockID, o.AppHash = "block-catchup", "app-catchup"
			}
			if event == RestartComplete {
				o.Height, o.BlockID, o.AppHash = 515, "block-restart", "app-restart"
			}
			obs = append(obs, o)
		}
	}
	return Trace{Binding: b, Observations: obs}
}

func obsForValidator(observations []Observation, validator string) []Observation {
	out := []Observation{}
	for _, o := range observations {
		if o.ValidatorID == validator {
			out = append(out, o)
		}
	}
	return out
}

func requirements(cases ...Case) Requirements {
	return Requirements{Validators: []string{"v1", "v2"}, Nodes: []string{"node-v1", "node-v2"}, RecoveryArtifactDigest: strings.Repeat("d", 64), StandardArtifactDigest: strings.Repeat("e", 64), Height: 10, BlockID: "block-H", AppHash: "app-H", RequiredEvidence: []string{"receipt"}, VerifiedEvidenceDigests: map[string]bool{strings.Repeat("f", 64): true}, Cases: cases, ExpectedUpdates: map[Case]int{OneUpdate: 1, TwoUpdates: 2}, MinimumValidators: 2, ValidatorSetHashes: map[int64]string{1: strings.Repeat("9", 64), 2: strings.Repeat("8", 64), 3: strings.Repeat("7", 64)}, FirstLifecycleEpoch: 1, CatchupHeight: 515, CatchupBlockID: "block-catchup", CatchupAppHash: "app-catchup", LaggingValidator: "v2", RestartHeight: 515, RestartBlockID: "block-restart", RestartAppHash: "app-restart"}
}

func TestValidateSuiteKeepsCasesDistinctAndDoesNotQualifyRuntime(t *testing.T) {
	cases := []Case{OneUpdate, TwoUpdates, DuplicateControl, SameHRepair, StandardHPlusOne, Restart, LateCatchup, Lifecycle}
	traces := make([]Trace, 0, len(cases))
	for i, c := range cases {
		traces = append(traces, testTrace(c, string(rune('a'+i))))
	}
	results, err := ValidateSuite(traces, requirements(cases...))
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != len(cases) {
		t.Fatalf("got %d results", len(results))
	}
	for _, result := range results {
		if !result.ConsistencyChecked {
			t.Fatal("consistency not checked")
		}
	}
}

func TestThreeNodesWithSingletonValidatorCannotSatisfyMultiValidatorCase(t *testing.T) {
	req := requirements(OneUpdate)
	req.Validators = []string{"only-validator"}
	req.Nodes = []string{"node-a", "node-b", "node-c"}
	req.MinimumValidators = 1
	req.MinimumValidatorsByCase = map[Case]int{OneUpdate: 2}
	tr := testTrace(OneUpdate, "singleton")
	tr.Observations = tr.Observations[:1]
	for i := range tr.Observations {
		tr.Observations[i].ValidatorID = "only-validator"
		tr.Observations[i].NodeID = []string{"node-a", "node-b", "node-c"}[i]
	}
	if _, err := Validate(tr, req); err == nil {
		t.Fatal("three node IDs were counted as multiple validators")
	}
}

func TestReproductionCaseCanRecordSingletonWithoutQualification(t *testing.T) {
	req := requirements(OneUpdate)
	req.Validators = []string{"only-validator"}
	req.Nodes = []string{"node-a", "node-b", "node-c"}
	req.MinimumValidators = 1
	tr := testTrace(OneUpdate, "singleton-reproduction")
	tr.Observations = tr.Observations[:1]
	for i := range tr.Observations {
		tr.Observations[i].ValidatorID = "only-validator"
		tr.Observations[i].NodeID = []string{"node-a", "node-b", "node-c"}[i]
	}
	result, err := Validate(tr, req)
	if err != nil {
		t.Fatal(err)
	}
	if !result.ConsistencyChecked {
		t.Fatal("singleton reproduction was not consistency checked")
	}
}

func TestLifecycleRequiresTwoFullEpochs(t *testing.T) {
	tr := testTrace(Lifecycle, "lifecycle")
	tr.Observations[4].Event = EpochComplete // omit the second PoC stage
	if _, err := Validate(tr, requirements(Lifecycle)); err == nil {
		t.Fatal("incomplete second epoch accepted")
	}
}

func TestLifecycleRequiresRestartAfterBothRotations(t *testing.T) {
	tr := testTrace(Lifecycle, "lifecycle-without-restart")
	tr.Observations = tr.Observations[:len(tr.Observations)-1]
	if _, err := Validate(tr, requirements(Lifecycle)); err == nil {
		t.Fatal("two epochs without a later standard-runtime restart accepted")
	}
}

func TestLifecycleRequiresRunBoundValidatorSetTransitionAtEachRotation(t *testing.T) {
	tr := testTrace(Lifecycle, "lifecycle-without-set-transition")
	for i := range tr.Observations {
		if tr.Observations[i].Event == RotationComplete {
			tr.Observations[i].NextValidatorSetHash = tr.Observations[i].ValidatorSetHash
		}
	}
	if _, err := Validate(tr, requirements(Lifecycle)); err == nil {
		t.Fatal("rotation without a validator-set transition accepted")
	}
}

func TestOneAndTwoUpdateCasesRequireTheirTypedCounts(t *testing.T) {
	tr := testTrace(TwoUpdates, "wrong-update-count")
	for i := range tr.Observations {
		tr.Observations[i].AppliedUpdateCount = 1
	}
	if _, err := Validate(tr, requirements(TwoUpdates)); err == nil {
		t.Fatal("one-update trace accepted for two-update case")
	}
}

func TestHeightOnlyRestartCannotSatisfyLateCatchup(t *testing.T) {
	tr := testTrace(LateCatchup, "height-only")
	for i := range tr.Observations {
		tr.Observations[i].CatchupFromHeight = tr.Observations[i].Height
	}
	if _, err := Validate(tr, requirements(LateCatchup)); err == nil {
		t.Fatal("height without a lag interval accepted as catchup")
	}
}

func TestCatchupRequiresReplayEvidence(t *testing.T) {
	tr := testTrace(LateCatchup, "without-replay-proof")
	tr.Observations[0].ReplayEvidenceDigest = ""
	if _, err := Validate(tr, requirements(LateCatchup)); err == nil {
		t.Fatal("height alignment without replay evidence accepted")
	}
}

func TestUnregisteredDigestReferenceIsNotEvidence(t *testing.T) {
	tr := testTrace(OneUpdate, "unregistered")
	req := requirements(OneUpdate)
	req.VerifiedEvidenceDigests = nil
	if _, err := Validate(tr, req); err == nil {
		t.Fatal("well-formed but unregistered digest was treated as evidence")
	}
}

func TestCommitBarrierNeedsEveryVerifiedReplayStage(t *testing.T) {
	tr := testTrace(SameHRepair, "incomplete-barrier")
	tr.Observations[1].BarrierStageDigests = map[string]string{"consensus-finalize": strings.Repeat("f", 64)}
	if _, err := Validate(tr, requirements(SameHRepair)); err == nil {
		t.Fatal("partial replay barrier accepted")
	}
}

func TestRejectsMissingStaleOutOfOrderMixedRunAndWrongArtifact(t *testing.T) {
	req := requirements(OneUpdate)
	valid := testTrace(OneUpdate, "run-a")
	mutations := map[string]func(*Trace){
		"missing evidence": func(tr *Trace) { tr.Observations[0].Evidence = nil },
		"stale binding":    func(tr *Trace) { tr.Observations[0].BindingDigest = strings.Repeat("0", 64) },
		"out of order":     func(tr *Trace) { tr.Observations[1].Sequence = tr.Observations[0].Sequence },
		"mixed run":        func(tr *Trace) { tr.Observations[0].RunID = "other" },
		"wrong artifact":   func(tr *Trace) { tr.Observations[0].ArtifactDigest = strings.Repeat("9", 64) },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			tr := valid
			tr.Observations = append([]Observation(nil), valid.Observations...)
			mutate(&tr)
			if _, err := Validate(tr, req); err == nil {
				t.Fatal("invalid trace accepted")
			}
		})
	}
}

func TestSuiteRejectsRunReuse(t *testing.T) {
	traces := []Trace{testTrace(OneUpdate, "same"), testTrace(TwoUpdates, "same")}
	if _, err := ValidateSuite(traces, requirements(OneUpdate, TwoUpdates)); err == nil {
		t.Fatal("same run accepted for distinct cases")
	}
}
