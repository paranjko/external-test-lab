package coregate

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

const testAppHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const testPriorAppHash = "1111111111111111111111111111111111111111111111111111111111111111"
const testBlockID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const testPartSetHash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
const testValidatorSetHash = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
const testCommitHash = "9999999999999999999999999999999999999999999999999999999999999999"
const testSourceCommit = "8daa0f0f0ab7df55d1fcaff4cafcb3897211feec"
const testHPlusOneBlockID = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

type stores struct {
	h           int64
	hash, block string
}

func (s stores) ReadApplication(context.Context, string) (PersistedState, error) {
	return PersistedState{Node: "n1", Store: "application", RunID: "run-1", BindingDigest: strings.Repeat("a", 64), Height: s.h, AppHash: s.hash}, nil
}
func (s stores) ReadCometState(context.Context, string) (PersistedState, error) {
	return PersistedState{Node: "n1", Store: "comet_state", RunID: "run-1", BindingDigest: strings.Repeat("a", 64), Height: s.h, AppHash: s.hash, BlockID: s.block, BlockIDPartSetHash: testPartSetHash, BlockIDPartSetTotal: 1}, nil
}
func (s stores) ReadBlockStore(_ context.Context, _ string, h int64) (PersistedState, error) {
	return proofStoreState(h, s.block, []byte("certificate"), []byte("set")), nil
}

type rawStores struct {
	stores
	commit, validators []byte
}

func (s rawStores) ReadBlockStore(_ context.Context, _ string, h int64) (PersistedState, error) {
	commit, validators := s.commit, s.validators
	if commit == nil {
		commit = []byte("certificate")
	}
	if validators == nil {
		validators = []byte("set")
	}
	return proofStoreState(h, s.block, commit, validators), nil
}

func proofStoreState(h int64, block string, commit, validators []byte) PersistedState {
	return PersistedState{Node: "n1", Store: "blockstore", RunID: "run-1", BindingDigest: strings.Repeat("a", 64), Height: h, BlockID: block, HeaderAppHash: testPriorAppHash, BlockIDPartSetHash: testPartSetHash, BlockIDPartSetTotal: 1, SeenCommitHeight: h, SeenCommitHash: testCommitHash, SeenCommitBlockID: block, SeenCommit: commit, ValidatorSet: validators}
}

type verifier struct{ fail bool }

func (v verifier) VerifySeenCommit(context.Context, string, []byte, []byte, string, string, uint32, int64, string, string) (QuorumProof, error) {
	if v.fail {
		return QuorumProof{}, errors.New("bad signatures")
	}
	return QuorumProof{BlockID: testBlockID, ValidatorSetHash: testValidatorSetHash, SignedPower: 3, TotalPower: 4, Signers: 3}, nil
}

type versionedVerifierProbe struct {
	chainID          string
	commit           []byte
	validators       []byte
	height           int64
	validatorSetHash string
}

func (v *versionedVerifierProbe) VerifySeenCommit(_ context.Context, chainID string, commit, validators []byte, _ string, _ string, _ uint32, height int64, _ string, validatorSetHash string) (QuorumProof, error) {
	v.chainID, v.commit, v.validators, v.height, v.validatorSetHash = chainID, append([]byte(nil), commit...), append([]byte(nil), validators...), height, validatorSetHash
	if string(commit) != "certificate" || string(validators) != "set" {
		return QuorumProof{}, errors.New("versioned verifier rejected malformed commit or validator-set mismatch")
	}
	return QuorumProof{BlockID: testBlockID, ValidatorSetHash: testValidatorSetHash, SignedPower: 3, TotalPower: 4, Signers: 3}, nil
}

type barriers struct{}

func (barriers) VerifyCommitBarriers(_ context.Context, n string, h int64, b string) ([]BarrierReceipt, error) {
	receipts := make([]BarrierReceipt, 0, 3)
	for _, stage := range []BarrierStage{HandshakeReplay, HandshakeAlreadySynced, ConsensusFinalize} {
		receipts = append(receipts, BarrierReceipt{Node: n, RunID: "run-1", BindingDigest: strings.Repeat("a", 64), ChainID: "chain", Stage: string(stage), BinaryIdentity: fixtureRecovery(), AppHash: testAppHash, Height: h, BlockID: b, BlockIDPartSetHash: testPartSetHash, BlockIDPartSetTotal: 1, ReceiptDigest: "durable", AfterAppCommit: true, AfterCometStateSave: true, BeforeNextHeightScheduling: true, ProcessStopped: true})
	}
	return receipts, nil
}

type scenarios struct {
	crashes   []CrashObservation
	handoff   HandoffProof
	late      LateReplayProof
	staleLate bool
}

func (s scenarios) VerifyCrashBoundaries(context.Context, string, int64) ([]CrashObservation, error) {
	for i := range s.crashes {
		s.crashes[i].RunID = "run-1"
		s.crashes[i].BindingDigest = strings.Repeat("a", 64)
	}
	return s.crashes, nil
}
func (s scenarios) VerifyHandoff(context.Context, string, int64) (HandoffProof, error) {
	s.handoff.RunID = "run-1"
	s.handoff.BindingDigest = strings.Repeat("a", 64)
	return s.handoff, nil
}
func (s scenarios) VerifyLateReplay(context.Context, string, int64) (LateReplayProof, error) {
	s.late.RunID = "run-1"
	s.late.BindingDigest = strings.Repeat("a", 64)
	s.late.ReplayPartSetHash = testPartSetHash
	s.late.ReplayPartSetTotal = 1
	if s.staleLate {
		s.late.BindingDigest = strings.Repeat("b", 64)
	}
	return s.late, nil
}

func fixture() (Expected, Evidence, scenarios) {
	recovery := fixtureRecovery()
	standard := ArtifactIdentity{Role: "standard", Version: "2", SHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", ExecutableSHA256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", SourceCommit: testSourceCommit, Runtime: "image@sha256:standard"}
	w := Expected{RunID: "run-1", BindingDigest: strings.Repeat("a", 64), RecoveryArtifact: recovery, StandardArtifact: standard, ChainID: "chain", Height: 10, BlockID: testBlockID, BlockIDPartSetHash: testPartSetHash, BlockIDPartSetTotal: 1, AppHash: testAppHash, PriorAppHash: testPriorAppHash, ValidatorSetHash: testValidatorSetHash, ValidatorCount: 1, ValidatorTotalPower: 10, SeenCommitHash: testCommitHash, Nodes: []string{"n1"}, BarrierStages: []BarrierStage{HandshakeReplay, HandshakeAlreadySynced, ConsensusFinalize}}
	e := Evidence{RunID: "run-1", BindingDigest: strings.Repeat("a", 64), RecoveryArtifact: recovery, StandardArtifact: standard}
	s := scenarios{crashes: []CrashObservation{
		{Node: "n1", BinaryIdentity: recovery, Boundary: BeforeAppCommit, App: 9, CometState: 9, BlockStore: 10, StartupPath: "replay_saved_block_with_recovery_binary"},
		{Node: "n1", BinaryIdentity: recovery, Boundary: AfterAppBeforeState, App: 10, CometState: 9, BlockStore: 10, StartupPath: "replay_saved_finalize_response_without_migration"},
		{Node: "n1", BinaryIdentity: recovery, Boundary: AfterStateBeforeNext, App: 10, CometState: 10, BlockStore: 10, StartupPath: "resume_from_committed_height"},
	}, handoff: HandoffProof{Node: "n1", RecoveryIdentity: recovery, StandardIdentity: standard, RecoveryProcessedHeight: 10, StandardStartedHeight: 10, StandardCommittedHeight: 11, HPlusOnePreviousAppHash: testAppHash, HPlusOneBlockID: testHPlusOneBlockID, HPlusOnePartSetHash: testPartSetHash, HPlusOnePartSetTotal: 1, HPlusOneAppHash: testAppHash}, late: LateReplayProof{Node: "n1", OldBinaryFailedAtDuplicate: true, RecoveryIdentity: recovery, RecoveryReplayedHeight: 10, ReplayBlockID: testBlockID, ReplayAppHash: testAppHash, ReplayPartSetHash: testPartSetHash, ReplayPartSetTotal: 1, NoSigning: true, StandardIdentity: standard, StandardStartedAt: 10, StandardCommittedHeight: 11, HPlusOneBlockID: testHPlusOneBlockID, HPlusOnePartSetHash: testPartSetHash, HPlusOnePartSetTotal: 1, HPlusOneHeaderAppHash: testAppHash, HPlusOneAppHash: testAppHash}}
	return w, e, s
}

func fixtureRecovery() ArtifactIdentity {
	return ArtifactIdentity{Role: "recovery", Version: "1", SHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ExecutableSHA256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", SourceCommit: testSourceCommit, Runtime: "image@sha256:recovery"}
}
func TestQualificationPassRequiresAllOfflineProofs(t *testing.T) {
	w, e, s := fixture()
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Pass || r.Qualification != "consistency_checked" || r.CoreRepairQualified || r.ScopeNote == "" {
		t.Fatalf("unexpected result: %+v", r)
	}
}
func TestQualificationRejectsArtifactSubstitution(t *testing.T) {
	w, e, s := fixture()
	e.StandardArtifact.SHA256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected fail: %+v", r)
	}
}
func TestQualificationRejectsExecutableBinaryDrift(t *testing.T) {
	w, e, s := fixture()
	e.RecoveryArtifact.ExecutableSHA256 = strings.Repeat("e", 64)
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected executable drift failure: %+v", r)
	}
}
func TestQualificationRejectsPersistedStoreDisagreement(t *testing.T) {
	w, e, s := fixture()
	r := Qualify(context.Background(), w, e, stores{9, "old", testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected fail: %+v", r)
	}
}
func TestQualificationRequiresCryptographicVerifier(t *testing.T) {
	w, e, s := fixture()
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{true}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected fail: %+v", r)
	}
}

func TestQualificationPassesSeenCommitAtHWithChainIDToVerifier(t *testing.T) {
	w, e, s := fixture()
	probe := &versionedVerifierProbe{}
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, probe, barriers{}, s)
	if r.Verdict != contract.Pass {
		t.Fatalf("expected pass from versioned verifier proof: %+v", r)
	}
	if probe.chainID != w.ChainID || probe.height != w.Height || probe.validatorSetHash != w.ValidatorSetHash || string(probe.commit) != "certificate" || string(probe.validators) != "set" {
		t.Fatalf("verifier inputs do not match persisted Commit(H): chain=%q height=%d set=%q commit=%q validators=%q", probe.chainID, probe.height, probe.validatorSetHash, probe.commit, probe.validators)
	}
}

func TestQualificationRejectsVerifierReportedTruncatedCommitOrWrongValidatorSet(t *testing.T) {
	for _, tc := range []struct {
		name               string
		commit, validators []byte
	}{
		{name: "truncated commit bytes", commit: []byte{0x08, 0x01}},
		{name: "wrong validator set bytes", validators: []byte("different validator set")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w, e, s := fixture()
			probe := &versionedVerifierProbe{}
			r := Qualify(context.Background(), w, e, rawStores{stores: stores{10, testAppHash, testBlockID}, commit: tc.commit, validators: tc.validators}, probe, barriers{}, s)
			if r.Verdict != contract.Fail {
				t.Fatalf("verifier rejection must fail qualification: %+v", r)
			}
			if probe.height != w.Height || probe.chainID != w.ChainID || probe.validatorSetHash != w.ValidatorSetHash {
				t.Fatalf("verifier did not receive exact binding: %+v", probe)
			}
		})
	}
}
func TestQualificationMissingBarrierIsBlocked(t *testing.T) {
	w, e, s := fixture()
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, nil, s)
	if r.Verdict != contract.VerdictBlocked {
		t.Fatalf("expected blocked: %+v", r)
	}
}
func TestQualificationRejectsCrashBoundaryMisclassification(t *testing.T) {
	w, e, s := fixture()
	s.crashes[0].App = 10
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected fail: %+v", r)
	}
}
func TestQualificationRequiresLateReplayNegativeControl(t *testing.T) {
	w, e, s := fixture()
	s.late.OldBinaryFailedAtDuplicate = false
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected fail: %+v", r)
	}
}

func TestQualificationRejectsLateReplayOnWrongStandardBinary(t *testing.T) {
	w, e, s := fixture()
	s.late.StandardIdentity.SHA256 = strings.Repeat("c", 64)
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected wrong-binary failure, got %+v", r)
	}
}

func TestQualificationRejectsStaleRunEvidence(t *testing.T) {
	w, e, s := fixture()
	s.staleLate = true
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriers{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected stale evidence failure, got %+v", r)
	}
}

type barriersBeforeStateSave struct{}

func (barriersBeforeStateSave) VerifyCommitBarriers(_ context.Context, n string, h int64, id string) ([]BarrierReceipt, error) {
	receipts := make([]BarrierReceipt, 0, 3)
	for _, stage := range []BarrierStage{HandshakeReplay, HandshakeAlreadySynced, ConsensusFinalize} {
		receipts = append(receipts, BarrierReceipt{Node: n, RunID: "run-1", BindingDigest: strings.Repeat("a", 64), ChainID: "chain", Stage: string(stage), BinaryIdentity: fixtureRecovery(), AppHash: testAppHash, Height: h, BlockID: id, BlockIDPartSetHash: testPartSetHash, BlockIDPartSetTotal: 1, ReceiptDigest: "durable", AfterAppCommit: true, AfterCometStateSave: false, BeforeNextHeightScheduling: true, ProcessStopped: true})
	}
	return receipts, nil
}
func TestQualificationRejectsBarrierBeforeCometStateSave(t *testing.T) {
	w, e, s := fixture()
	r := Qualify(context.Background(), w, e, stores{10, testAppHash, testBlockID}, verifier{}, barriersBeforeStateSave{}, s)
	if r.Verdict != contract.Fail {
		t.Fatalf("expected barrier failure: %+v", r)
	}
}

const inspectorFixture = `{"observed_utc":"2026-10-19T13:32:52Z","copy_marker":{"kind":"gnklab-readonly-db-copy-v1","source_root":"redacted","created_utc":"2026-10-19T13:32:37Z"},"application":{"height":370,"app_hash_hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"comet_state":{"height":370,"chain_id":"synthetic","app_hash_hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","last_block_id_hash_hex":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","validator_count":1,"validator_total_power":10},"blockstore":{"height":370,"block_id_hash_hex":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","block_id_part_set_hash_hex":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","block_id_part_set_total":1,"header_app_hash_hex":"1111111111111111111111111111111111111111111111111111111111111111","seen_commit_height":370,"seen_commit_hash_hex":"9999999999999999999999999999999999999999999999999999999999999999","seen_commit_block_id_hash_hex":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","seen_commit_verification":"valid","seen_commit_signatures":1,"seen_commit_voting_power":10},"kv_dump_record_count":718,"kv_dump_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}`

func TestInspectorSummaryParserCannotQualifyRawCommitOrRun(t *testing.T) {
	a, err := ParseInspectorSummary("genesis", []byte(inspectorFixture))
	if err != nil {
		t.Fatal(err)
	}
	b, err := ParseInspectorSummary("join1", []byte(inspectorFixture))
	if err != nil {
		t.Fatal(err)
	}
	w := Expected{ChainID: "synthetic", Height: 370, BlockID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", BlockIDPartSetHash: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", BlockIDPartSetTotal: 1, AppHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", PriorAppHash: "1111111111111111111111111111111111111111111111111111111111111111", SeenCommitHash: testCommitHash, ValidatorCount: 1, ValidatorTotalPower: 10, Nodes: []string{"genesis", "join1"}}
	r := CompareInspectorSummaries(w, []InspectorSummary{a, b})
	if !r.StateConsistent || r.QuorumVerified || r.CoreRepairQualified || r.Verdict != contract.VerdictBlocked {
		t.Fatalf("summary exceeded available evidence: %+v", r)
	}
}
func TestInspectorSummaryComparisonRejectsSameHeightHashDisagreement(t *testing.T) {
	a, err := ParseInspectorSummary("genesis", []byte(inspectorFixture))
	if err != nil {
		t.Fatal(err)
	}
	b, err := ParseInspectorSummary("join1", []byte(inspectorFixture))
	if err != nil {
		t.Fatal(err)
	}
	b.CometAppHash = strings.Repeat("e", 64)
	w := Expected{ChainID: "synthetic", Height: 370, BlockID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", BlockIDPartSetHash: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", BlockIDPartSetTotal: 1, AppHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ValidatorCount: 1, ValidatorTotalPower: 10, Nodes: []string{"genesis", "join1"}}
	r := CompareInspectorSummaries(w, []InspectorSummary{a, b})
	if r.StateConsistent || r.Verdict != contract.VerdictBlocked {
		t.Fatalf("expected state mismatch: %+v", r)
	}
}

func TestInspectorSummaryKeepsThreeNodeTopologyDistinctFromSingletonHSet(t *testing.T) {
	a, err := ParseInspectorSummary("genesis", []byte(inspectorFixture))
	if err != nil {
		t.Fatal(err)
	}
	w := Expected{ChainID: "synthetic", Height: 370, BlockID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", BlockIDPartSetHash: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", BlockIDPartSetTotal: 1, AppHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", PriorAppHash: "1111111111111111111111111111111111111111111111111111111111111111", SeenCommitHash: testCommitHash, ValidatorCount: 3, ValidatorTotalPower: 30, Nodes: []string{"genesis"}}
	r := CompareInspectorSummaries(w, []InspectorSummary{a})
	if r.StateConsistent || r.Verdict != contract.VerdictBlocked {
		t.Fatalf("singleton H quorum was mistaken for three validators: %+v", r)
	}
}

func TestQualificationRequiresCrashEvidenceForEachNode(t *testing.T) {
	w, _, _ := fixture()
	w.Nodes = []string{"n1", "n2"}
	missing, failures := []string{}, []string{}
	observed := []CrashObservation{
		{Node: "n1", RunID: w.RunID, BindingDigest: w.BindingDigest, BinaryIdentity: w.RecoveryArtifact, Boundary: BeforeAppCommit, App: 9, CometState: 9, BlockStore: 10, StartupPath: "replay_saved_block_with_recovery_binary"},
		{Node: "n1", RunID: w.RunID, BindingDigest: w.BindingDigest, BinaryIdentity: w.RecoveryArtifact, Boundary: AfterAppBeforeState, App: 10, CometState: 9, BlockStore: 10, StartupPath: "replay_saved_finalize_response_without_migration"},
		{Node: "n1", RunID: w.RunID, BindingDigest: w.BindingDigest, BinaryIdentity: w.RecoveryArtifact, Boundary: AfterStateBeforeNext, App: 10, CometState: 10, BlockStore: 10, StartupPath: "resume_from_committed_height"},
	}
	checkCrashProofs(w, observed, &missing, &failures)
	if len(missing) == 0 || len(failures) != 0 {
		t.Fatalf("per-node gap not detected: missing=%v failures=%v", missing, failures)
	}
}
func TestInspectorSummaryParserRejectsDuplicateKeys(t *testing.T) {
	raw := strings.Replace(inspectorFixture, "\"height\":370", "\"height\":370,\"height\":370", 1)
	if _, err := ParseInspectorSummary("n", []byte(raw)); err == nil {
		t.Fatal("expected duplicate key error")
	}
}
