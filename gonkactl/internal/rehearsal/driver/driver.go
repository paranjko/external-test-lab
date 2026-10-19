// Package driver coordinates the ordered synthetic recovery replay. It is not
// a qualification verdict: every external evidence adapter is a trust input,
// and production recovery remains unqualified until its source is qualified.
package driver

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/isolation"
	"golang.org/x/sys/unix"
)

var (
	ErrUnavailable  = errors.New("rehearsal driver phase adapter unavailable")
	ErrPrecondition = errors.New("rehearsal driver phase predecessor or evidence precondition failed")
	ErrUnknown      = errors.New("rehearsal driver mutation outcome unknown; reconciliation required")
	ErrJournal      = errors.New("rehearsal driver durable journal operation failed")
	ErrPlan         = errors.New("invalid rehearsal driver plan")
)

type Step string

const (
	ControlCreate            Step = "control.create"
	ControlStart             Step = "control.start"
	ControlFailureObserved   Step = "control.failure-observed"
	ControlStop              Step = "control.stop"
	RecoveryCreate           Step = "recovery.create"
	BarrierPrepared          Step = "recovery.barrier-prepared"
	RecoveryStart            Step = "recovery.start"
	BarrierValidated         Step = "recovery.barrier-validated"
	RecoveryKill             Step = "recovery.kill"
	OfflineStoresValidated   Step = "recovery.offline-stores-validated"
	StandardCreate           Step = "standard.create"
	StandardStart            Step = "standard.start"
	StandardHandoffValidated Step = "standard.handoff-validated"
	HPlusOneCollected        Step = "standard.hplusone-collected"
)

var orderedSteps = [...]Step{
	ControlCreate, ControlStart, ControlFailureObserved, ControlStop,
	RecoveryCreate, BarrierPrepared, RecoveryStart, BarrierValidated,
	RecoveryKill, OfflineStoresValidated, StandardCreate, StandardStart,
	StandardHandoffValidated, HPlusOneCollected,
}

type Record struct {
	Step     Step            `json:"step"`
	Evidence json.RawMessage `json:"evidence"`
}

// Ledger is a parent-owned durable receipt view. A pending or unknown mutation
// is terminal for automatic execution; this package never retries it.
type Ledger struct {
	BindingDigest string   `json:"binding_digest"`
	Completed     []Record `json:"completed"`
	Pending       *Step    `json:"pending,omitempty"`
	Unknown       bool     `json:"unknown,omitempty"`
}

// Journal is implemented by the parent-owned fsynced, run-owned ledger. Record
// is only for read-only observations; every runtime or filesystem mutation is
// wrapped by Begin/Complete, with Unknown used after uncertainty or a failed
// post-effect persistence operation.
type Journal interface {
	isolation.AdoptionAuthorizer
	Read(context.Context, string) (Ledger, error)
	Begin(context.Context, string, Step, json.RawMessage) error
	Complete(context.Context, string, Step, json.RawMessage) error
	Record(context.Context, string, Step, json.RawMessage) error
	Unknown(context.Context, string, Step, string) error
}

type Plan struct {
	Binding            contract.RunBinding
	NodeID             string
	ControlFailureKind string
	Control            isolation.ContainerSpec
	Recovery           isolation.ContainerSpec
	Standard           isolation.ContainerSpec
	Barrier            coregate.BarrierMarkerExpectation
	HPlusOne           coregate.HPlusOneExpectation
	BlockPartSize      uint32
	BarrierWait        time.Duration
	PollInterval       time.Duration
}

type ControlFailureEvidence struct {
	RunID         string `json:"run_id"`
	BindingDigest string `json:"binding_digest"`
	RuntimeID     string `json:"runtime_id"`
	FailureKind   string `json:"failure_kind"`
	ExitCode      int    `json:"exit_code"`
	RawSHA256     string `json:"raw_sha256"`
	Raw           []byte `json:"raw"`
}

// OfflineStoreSnapshot contains the complete logical contents and the
// independently observed metadata for one stopped store. Raw is the exact
// serialized full snapshot; it is pinned separately in the journal.
type OfflineStoreSnapshot struct {
	SchemaVersion string `json:"schema_version"`
	RunID         string `json:"run_id"`
	BindingDigest string `json:"binding_digest"`
	NodeID        string `json:"node_id"`
	RuntimeID     string `json:"runtime_id"`
	Store         string `json:"store"`
	Height        int64  `json:"height"`
	AppHash       string `json:"app_hash"`
	BlockID       string `json:"block_id"`
	PartSetHash   string `json:"part_set_hash"`
	PartSetTotal  uint32 `json:"part_set_total"`
	RawSnapshot   []byte `json:"raw_snapshot"`
}

type OfflineStoreEvidence struct {
	Snapshots []OfflineStoreSnapshot `json:"snapshots"`
	Digests   map[string]string      `json:"digests"`
}

type HandoffEvidence struct {
	RunID                   string `json:"run_id"`
	BindingDigest           string `json:"binding_digest"`
	RecoveryID              string `json:"recovery_id"`
	StandardID              string `json:"standard_id"`
	RecoveryBinaryDigest    string `json:"recovery_binary_digest"`
	StandardBinaryDigest    string `json:"standard_binary_digest"`
	RecoveryProcessedHeight int64  `json:"recovery_processed_height"`
	StandardStartedHeight   int64  `json:"standard_started_height"`
	RawSHA256               string `json:"raw_sha256"`
	Raw                     []byte `json:"raw"`
}

type HPlusOneEvidence struct {
	RunID         string `json:"run_id"`
	BindingDigest string `json:"binding_digest"`
	RuntimeID     string `json:"runtime_id"`
	RawSHA256     string `json:"raw_sha256"`
	Raw           []byte `json:"raw"`
}

// EvidenceHooks are trusted producer/inspector dependencies, not assertions
// supplied by a CLI caller. Return raw, independently sourced evidence; the
// coordinator validates binding, identities, full snapshots and H+1 bytes.
type EvidenceHooks interface {
	ObserveControlFailure(context.Context, contract.RunBinding, isolation.PinnedResource) (ControlFailureEvidence, error)
	ReadOfflineStores(context.Context, contract.RunBinding, isolation.PinnedResource) ([]OfflineStoreSnapshot, error)
	VerifyStandardHandoff(context.Context, contract.RunBinding, isolation.PinnedResource, isolation.PinnedResource) (HandoffEvidence, error)
	ReadHPlusOne(context.Context, contract.RunBinding, isolation.PinnedResource) (HPlusOneEvidence, error)
}

type Coordinator struct {
	binding       contract.RunBinding
	bindingDigest string
	plan          Plan
	runtime       *isolation.RuntimeAdapter
	runner        isolation.ProcessRunner
	executable    string
	journal       Journal
	hooks         EvidenceHooks
}

type Result struct {
	ControlPin  isolation.PinnedResource      `json:"control_pin"`
	RecoveryPin isolation.PinnedResource      `json:"recovery_pin"`
	StandardPin isolation.PinnedResource      `json:"standard_pin"`
	Barrier     coregate.BarrierMarker        `json:"barrier"`
	HPlusOne    coregate.HPlusOneVerification `json:"hplusone"`
}

// NewDockerCoordinator is the production constructor. It always builds the
// allowlisted native process runner and concrete RuntimeAdapter; process
// injection is deliberately private and only used by package tests.
func NewDockerCoordinator(plan Plan, executable string, journal Journal, hooks EvidenceHooks) (*Coordinator, error) {
	if nilLike(journal) || nilLike(hooks) {
		return nil, ErrUnavailable
	}
	operations := []isolation.Operation{
		isolation.OperationCreateContainer, isolation.OperationInspectImage,
		isolation.OperationInspectResources, isolation.OperationStartContainer,
		isolation.OperationStopContainer, isolation.OperationKillContainer,
		isolation.OperationRemoveContainer,
	}
	runner, err := isolation.NewNativeRunner(isolation.ProcessPolicy{
		Executables: []string{executable}, Operations: operations,
		Timeout: 10 * time.Minute, MaxOutputBytes: 16 << 20,
	})
	if err != nil {
		return nil, err
	}
	runtime, err := isolation.NewRuntimeAdapter(runner, executable, plan.Binding, journal)
	if err != nil {
		return nil, err
	}
	return newCoordinator(plan, runtime, runner, executable, journal, hooks)
}

func newCoordinator(plan Plan, runtime *isolation.RuntimeAdapter, runner isolation.ProcessRunner, executable string, journal Journal, hooks EvidenceHooks) (*Coordinator, error) {
	if runtime == nil || runner == nil || nilLike(journal) || nilLike(hooks) || validatePlan(plan) != nil {
		return nil, ErrPlan
	}
	digest, err := contract.Digest(plan.Binding)
	if err != nil {
		return nil, err
	}
	plan.Binding = cloneBinding(plan.Binding)
	if plan.BarrierWait <= 0 {
		plan.BarrierWait = 10 * time.Minute
	}
	if plan.PollInterval <= 0 {
		plan.PollInterval = time.Second
	}
	return &Coordinator{binding: plan.Binding, bindingDigest: digest, plan: plan, runtime: runtime, runner: runner, executable: executable, journal: journal, hooks: hooks}, nil
}

func validatePlan(p Plan) error {
	if contract.ValidateBinding(p.Binding) != nil || strings.TrimSpace(p.NodeID) == "" || strings.TrimSpace(p.ControlFailureKind) == "" || p.Barrier.ChainID != p.Binding.ChainID || p.Barrier.Height <= 0 || p.Barrier.Stage != coregate.HandshakeReplay || p.Barrier.Height != p.HPlusOne.Height || p.HPlusOne.RunID != p.Binding.RunID || p.HPlusOne.NodeID != p.NodeID || p.HPlusOne.ChainID != p.Binding.ChainID || p.HPlusOne.Height <= 0 || p.BlockPartSize == 0 {
		return ErrPlan
	}
	if p.Control.ValidateBinding(p.Binding) != nil || p.Recovery.ValidateBinding(p.Binding) != nil || p.Standard.ValidateBinding(p.Binding) != nil {
		return ErrPlan
	}
	if p.Control.SelectedBinaryRole != isolation.BinaryOriginal || p.Recovery.SelectedBinaryRole != isolation.BinaryRecovery || p.Standard.SelectedBinaryRole != isolation.BinaryOriginal {
		return ErrPlan
	}
	controlFork, recoveryFork, standardFork := selectedFork(p.Control), selectedFork(p.Recovery), selectedFork(p.Standard)
	if controlFork == "" || recoveryFork == "" || standardFork != recoveryFork || controlFork == recoveryFork {
		return ErrPlan
	}
	if p.Control.Name == p.Recovery.Name || p.Control.Name == p.Standard.Name || p.Recovery.Name == p.Standard.Name {
		return ErrPlan
	}
	// The coordinator owns network creation separately. A caller-pinned network
	// is not adopted implicitly; fail closed until a network receipt exists.
	if p.Control.Network != nil || p.Recovery.Network != nil || p.Standard.Network != nil {
		return ErrPlan
	}
	if !contract.IsDigest(p.Barrier.AppHash) || !contract.IsDigest(p.Barrier.BlockHash) || !contract.IsDigest(p.Barrier.PartSetHash) || p.Barrier.PartSetTotal == 0 || !contract.IsDigest(p.HPlusOne.BlockID) || !contract.IsDigest(p.HPlusOne.PartSetHash) || p.HPlusOne.PartSetTotal == 0 || p.HPlusOne.PreviousBlockID != p.Barrier.BlockHash || p.HPlusOne.PreviousPartSetHash != p.Barrier.PartSetHash || p.HPlusOne.PreviousPartSetTotal != p.Barrier.PartSetTotal || p.HPlusOne.HeaderAppHash != p.Barrier.AppHash {
		return ErrPlan
	}
	return nil
}

// Run resumes only from a complete, durable prefix. Every external mutation is
// preceded by journal intent. Existing intent/unknown state is never repeated.
func (c *Coordinator) Run(ctx context.Context) (Result, error) {
	var result Result
	if err := c.RunThrough(ctx, HPlusOneCollected); err != nil {
		return result, err
	}
	ledger, err := c.readLedger(ctx)
	if err != nil {
		return result, err
	}
	return c.resultFromLedger(ledger)
}

// RunThrough executes only the ordered durable prefix ending at target. It is
// the phase boundary used by the CLI: Stage owns the signerless control
// replay, while Run resumes at recovery creation. A previously completed
// prefix is adopted only through the run-owned journal and is never repeated.
func (c *Coordinator) RunThrough(ctx context.Context, target Step) error {
	if ctx == nil || !knownStep(target) {
		return ErrPrecondition
	}
	for {
		ledger, err := c.readLedger(ctx)
		if err != nil {
			return err
		}
		if err := c.adoptLedgerResources(ctx, ledger); err != nil {
			return err
		}
		if stepComplete(ledger, target) {
			return nil
		}
		if len(ledger.Completed) == len(orderedSteps) {
			return ErrPrecondition
		}
		step := orderedSteps[len(ledger.Completed)]
		if err := c.executeStep(ctx, step, ledger); err != nil {
			return fmt.Errorf("%s: %w", step, err)
		}
	}
}

func knownStep(target Step) bool {
	for _, step := range orderedSteps {
		if target == step {
			return true
		}
	}
	return false
}

func stepComplete(ledger Ledger, target Step) bool {
	for _, record := range ledger.Completed {
		if record.Step == target {
			return true
		}
	}
	return false
}

func (c *Coordinator) adoptLedgerResources(ctx context.Context, ledger Ledger) error {
	for _, step := range []Step{ControlCreate, RecoveryCreate, StandardCreate} {
		pin, err := findPin[isolation.PinnedResource](ledger, step)
		if errors.Is(err, ErrPrecondition) {
			continue
		}
		if err != nil || !c.validPinnedForStep(step, pin) {
			return ErrPrecondition
		}
		if err := c.runtime.Adopt(ctx, pin); err != nil {
			return fmt.Errorf("%w: journal-authorized %s adoption failed: %v", ErrPrecondition, step, err)
		}
	}
	return nil
}

func (c *Coordinator) executeStep(ctx context.Context, step Step, ledger Ledger) error {
	switch step {
	case ControlCreate:
		return c.mutate(ctx, step, nil, func() (any, error) { return c.runtime.Create(ctx, c.plan.Control) })
	case ControlStart:
		pin, err := findPin[isolation.PinnedResource](ledger, ControlCreate)
		if err != nil {
			return err
		}
		return c.mutate(ctx, step, pin, func() (any, error) { return nil, c.runtime.Start(ctx, pin) })
	case ControlFailureObserved:
		pin, err := findPin[isolation.PinnedResource](ledger, ControlCreate)
		if err != nil {
			return err
		}
		observation, err := c.hooks.ObserveControlFailure(ctx, cloneBinding(c.binding), pin)
		if err != nil {
			return fmt.Errorf("%w: standard control failure observation: %v", ErrUnavailable, err)
		}
		var observed controlFailureRecord
		if len(observation.Raw) == 0 || contract.DecodeStrict(observation.Raw, &observed) != nil || observed.RunID != observation.RunID || observed.BindingDigest != observation.BindingDigest || observed.RuntimeID != observation.RuntimeID || observed.FailureKind != observation.FailureKind || observed.ExitCode != observation.ExitCode || observation.FailureKind != c.plan.ControlFailureKind {
			return ErrPrecondition
		}
		resource, err := c.runtime.Inspect(ctx, pin)
		if err != nil || resource.Running || resource.StateStatus != "exited" || !resource.ExitCodeKnown || resource.ExitCode == 0 || observation.RunID != c.binding.RunID || observation.BindingDigest != c.bindingDigest || observation.RuntimeID != pin.ID || observation.ExitCode != resource.ExitCode || observation.FailureKind == "" || len(observation.Raw) == 0 || observation.RawSHA256 != contract.PayloadDigest(observation.Raw) {
			return ErrPrecondition
		}
		return c.record(ctx, step, observation)
	case ControlStop:
		pin, err := findPin[isolation.PinnedResource](ledger, ControlCreate)
		if err != nil {
			return err
		}
		return c.mutate(ctx, step, pin, func() (any, error) {
			if err := c.runtime.Stop(ctx, pin); err != nil {
				return nil, err
			}
			r, err := c.runtime.Inspect(ctx, pin)
			if err != nil || r.Running || r.StateStatus != "exited" {
				return nil, ErrPrecondition
			}
			return r, nil
		})
	case RecoveryCreate:
		return c.mutate(ctx, step, nil, func() (any, error) { return c.runtime.Create(ctx, c.plan.Recovery) })
	case BarrierPrepared:
		return c.mutate(ctx, step, nil, func() (any, error) { return c.prepareBarrier() })
	case RecoveryStart:
		pin, err := findPin[isolation.PinnedResource](ledger, RecoveryCreate)
		if err != nil {
			return err
		}
		prepared, err := findEvidence[barrierPreparedReceipt](ledger, BarrierPrepared)
		if err != nil {
			return err
		}
		return c.mutate(ctx, step, struct {
			Pin      isolation.PinnedResource `json:"pin"`
			Prepared barrierPreparedReceipt   `json:"prepared"`
		}{pin, prepared}, func() (any, error) {
			if err := c.ensureMarkerAbsent(prepared); err != nil {
				return nil, err
			}
			started := time.Now().UTC()
			if err := c.runtime.Start(ctx, pin); err != nil {
				return nil, err
			}
			return startReceipt{Pin: pin, StartedAt: started}, nil
		})
	case BarrierValidated:
		pin, err := findPin[isolation.PinnedResource](ledger, RecoveryCreate)
		if err != nil {
			return err
		}
		start, err := findEvidence[startReceipt](ledger, RecoveryStart)
		if err != nil {
			return err
		}
		prepared, err := findEvidence[barrierPreparedReceipt](ledger, BarrierPrepared)
		if err != nil {
			return err
		}
		barrier, err := c.awaitBarrier(ctx, pin, start.StartedAt, prepared)
		if err != nil {
			return err
		}
		return c.record(ctx, step, barrier)
	case RecoveryKill:
		pin, err := findPin[isolation.PinnedResource](ledger, RecoveryCreate)
		if err != nil {
			return err
		}
		if _, err := findEvidence[barrierReceipt](ledger, BarrierValidated); err != nil {
			return err
		}
		return c.mutate(ctx, step, pin, func() (any, error) { return nil, c.runtime.KillRecovery(ctx, pin) })
	case OfflineStoresValidated:
		pin, err := findPin[isolation.PinnedResource](ledger, RecoveryCreate)
		if err != nil {
			return err
		}
		resource, err := c.runtime.Inspect(ctx, pin)
		if err != nil || resource.Running || resource.StateStatus != "exited" || !resource.ExitCodeKnown || resource.ExitCode != 137 {
			return ErrPrecondition
		}
		snapshots, err := c.hooks.ReadOfflineStores(ctx, cloneBinding(c.binding), pin)
		if err != nil {
			return fmt.Errorf("%w: independent stopped-store reader: %v", ErrUnavailable, err)
		}
		proof, err := c.validateStores(pin, snapshots)
		if err != nil {
			return err
		}
		return c.record(ctx, step, proof)
	case StandardCreate:
		if _, err := findEvidence[OfflineStoreEvidence](ledger, OfflineStoresValidated); err != nil {
			return err
		}
		return c.mutate(ctx, step, nil, func() (any, error) { return c.runtime.Create(ctx, c.plan.Standard) })
	case StandardStart:
		pin, err := findPin[isolation.PinnedResource](ledger, StandardCreate)
		if err != nil {
			return err
		}
		return c.mutate(ctx, step, pin, func() (any, error) { return nil, c.runtime.Start(ctx, pin) })
	case StandardHandoffValidated:
		recovery, err := findPin[isolation.PinnedResource](ledger, RecoveryCreate)
		if err != nil {
			return err
		}
		standard, err := findPin[isolation.PinnedResource](ledger, StandardCreate)
		if err != nil {
			return err
		}
		resource, err := c.runtime.Inspect(ctx, standard)
		if err != nil || !resource.Running {
			return ErrPrecondition
		}
		handoff, err := c.hooks.VerifyStandardHandoff(ctx, cloneBinding(c.binding), recovery, standard)
		if err != nil {
			return fmt.Errorf("%w: exact standard handoff observer: %v", ErrUnavailable, err)
		}
		var persisted handoffRecord
		if len(handoff.Raw) == 0 || handoff.RawSHA256 != contract.PayloadDigest(handoff.Raw) || contract.DecodeStrict(handoff.Raw, &persisted) != nil || persisted.RunID != handoff.RunID || persisted.BindingDigest != handoff.BindingDigest || persisted.RecoveryID != handoff.RecoveryID || persisted.StandardID != handoff.StandardID || persisted.RecoveryBinaryDigest != handoff.RecoveryBinaryDigest || persisted.StandardBinaryDigest != handoff.StandardBinaryDigest || persisted.RecoveryProcessedHeight != handoff.RecoveryProcessedHeight || persisted.StandardStartedHeight != handoff.StandardStartedHeight || handoff.RunID != c.binding.RunID || handoff.BindingDigest != c.bindingDigest || handoff.RecoveryID != recovery.ID || handoff.StandardID != standard.ID || handoff.RecoveryBinaryDigest != recovery.SelectedBinaryDigest || handoff.StandardBinaryDigest != standard.SelectedBinaryDigest || handoff.RecoveryProcessedHeight != c.plan.Barrier.Height || handoff.StandardStartedHeight != c.plan.Barrier.Height {
			return ErrPrecondition
		}
		return c.record(ctx, step, handoff)
	case HPlusOneCollected:
		standard, err := findPin[isolation.PinnedResource](ledger, StandardCreate)
		if err != nil {
			return err
		}
		if _, err := findEvidence[HandoffEvidence](ledger, StandardHandoffValidated); err != nil {
			return err
		}
		resource, err := c.runtime.Inspect(ctx, standard)
		if err != nil || !resource.Running {
			return ErrPrecondition
		}
		out, err := c.hooks.ReadHPlusOne(ctx, cloneBinding(c.binding), standard)
		if err != nil {
			return fmt.Errorf("%w: post-standard H+1 evidence source: %v", ErrUnavailable, err)
		}
		if out.RunID != c.binding.RunID || out.BindingDigest != c.bindingDigest || out.RuntimeID != standard.ID || len(out.Raw) == 0 || out.RawSHA256 != contract.PayloadDigest(out.Raw) {
			return ErrPrecondition
		}
		verified, err := coregate.VerifyPostStandardHPlusOne(ctx, out.Raw, coregate.CometBFT03821BlockDecoder{BlockPartSize: c.plan.BlockPartSize}, c.plan.HPlusOne)
		if err != nil {
			return fmt.Errorf("%w: H+1 verification: %v", ErrPrecondition, err)
		}
		return c.record(ctx, step, hplusReceipt{Evidence: out, Verification: verified})
	default:
		return ErrPrecondition
	}
}

type startReceipt struct {
	Pin       isolation.PinnedResource `json:"pin"`
	StartedAt time.Time                `json:"started_at"`
}
type barrierPreparedReceipt struct {
	ForkKey    string    `json:"fork_key"`
	Filename   string    `json:"filename"`
	PreparedAt time.Time `json:"prepared_at"`
}
type barrierReceipt struct {
	Marker     coregate.BarrierMarker `json:"marker"`
	Raw        []byte                 `json:"raw"`
	SHA256     string                 `json:"sha256"`
	ObservedAt time.Time              `json:"observed_at"`
	RuntimeID  string                 `json:"runtime_id"`
}
type hplusReceipt struct {
	Evidence     HPlusOneEvidence              `json:"evidence"`
	Verification coregate.HPlusOneVerification `json:"verification"`
}
type handoffRecord struct {
	RunID                   string `json:"run_id"`
	BindingDigest           string `json:"binding_digest"`
	RecoveryID              string `json:"recovery_id"`
	StandardID              string `json:"standard_id"`
	RecoveryBinaryDigest    string `json:"recovery_binary_digest"`
	StandardBinaryDigest    string `json:"standard_binary_digest"`
	RecoveryProcessedHeight int64  `json:"recovery_processed_height"`
	StandardStartedHeight   int64  `json:"standard_started_height"`
}
type controlFailureRecord struct {
	RunID         string `json:"run_id"`
	BindingDigest string `json:"binding_digest"`
	RuntimeID     string `json:"runtime_id"`
	FailureKind   string `json:"failure_kind"`
	ExitCode      int    `json:"exit_code"`
}

func (c *Coordinator) prepareBarrier() (barrierPreparedReceipt, error) {
	fork := selectedFork(c.plan.Recovery)
	rootPath := c.binding.Paths[fork]
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		return barrierPreparedReceipt{}, fmt.Errorf("%w: open recovery fork root: %v", ErrPrecondition, err)
	}
	defer root.Close()
	const dir = "gnklab0002-recovery-barrier"
	if err := root.Mkdir(dir, 0o700); err != nil {
		return barrierPreparedReceipt{}, fmt.Errorf("%w: recovery barrier directory must be absent: %v", ErrPrecondition, err)
	}
	markerDir, err := root.OpenRoot(dir)
	if err != nil {
		return barrierPreparedReceipt{}, err
	}
	defer markerDir.Close()
	filename := barrierFilename(c.plan.Barrier.Stage, c.plan.Barrier.Height)
	if _, err := markerDir.Lstat(filename); err == nil || !errors.Is(err, os.ErrNotExist) {
		return barrierPreparedReceipt{}, ErrPrecondition
	}
	return barrierPreparedReceipt{ForkKey: fork, Filename: filename, PreparedAt: time.Now().UTC()}, nil
}

func (c *Coordinator) ensureMarkerAbsent(prepared barrierPreparedReceipt) error {
	if prepared.ForkKey != selectedFork(c.plan.Recovery) || prepared.Filename != barrierFilename(c.plan.Barrier.Stage, c.plan.Barrier.Height) {
		return ErrPrecondition
	}
	root, err := os.OpenRoot(c.binding.Paths[prepared.ForkKey])
	if err != nil {
		return err
	}
	defer root.Close()
	dir, err := root.OpenRoot("gnklab0002-recovery-barrier")
	if err != nil {
		return err
	}
	defer dir.Close()
	if _, err := dir.Lstat(prepared.Filename); err == nil || !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: recovery marker must be absent immediately before launch", ErrPrecondition)
	}
	return nil
}

func (c *Coordinator) awaitBarrier(ctx context.Context, pin isolation.PinnedResource, started time.Time, prepared barrierPreparedReceipt) (barrierReceipt, error) {
	if prepared.ForkKey != selectedFork(c.plan.Recovery) || prepared.Filename != barrierFilename(c.plan.Barrier.Stage, c.plan.Barrier.Height) || !started.After(prepared.PreparedAt) || pin.SelectedBinaryRole != isolation.BinaryRecovery || pin.SelectedBinaryDigest != c.binding.InputDigests["recovery-binary"] {
		return barrierReceipt{}, ErrPrecondition
	}
	deadline := time.NewTimer(c.plan.BarrierWait)
	defer deadline.Stop()
	ticker := time.NewTicker(c.plan.PollInterval)
	defer ticker.Stop()
	for {
		resource, err := c.runtime.Inspect(ctx, pin)
		if err != nil {
			return barrierReceipt{}, err
		}
		if !resource.Running || resource.StateStatus != "running" {
			return barrierReceipt{}, fmt.Errorf("%w: recovery exited before fresh barrier", ErrPrecondition)
		}
		identity, err := c.inspectProcessIdentity(ctx, pin)
		if err != nil {
			return barrierReceipt{}, err
		}
		raw, modTime, err := readBoundMarker(c.binding.Paths[prepared.ForkKey], prepared.Filename)
		if err == nil {
			// Freshness is primarily established by the durable pre-start
			// absence check on a newly created directory. Allow coarse filesystem
			// mtime granularity while still rejecting substantially older files.
			if modTime.Before(started.Add(-2*time.Second)) || modTime.Before(prepared.PreparedAt.Add(-2*time.Second)) {
				return barrierReceipt{}, ErrPrecondition
			}
			want := c.plan.Barrier
			want.Hostname, want.PID = identity.Hostname, identity.PID
			marker, parseErr := coregate.ParseBarrierMarker(raw, want)
			if parseErr != nil {
				return barrierReceipt{}, parseErr
			}
			sum := sha256.Sum256(raw)
			return barrierReceipt{Marker: marker, Raw: raw, SHA256: hex.EncodeToString(sum[:]), ObservedAt: time.Now().UTC(), RuntimeID: pin.ID}, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return barrierReceipt{}, err
		}
		select {
		case <-ctx.Done():
			return barrierReceipt{}, ctx.Err()
		case <-deadline.C:
			return barrierReceipt{}, fmt.Errorf("%w: fresh recovery barrier timed out without changing container state", ErrUnavailable)
		case <-ticker.C:
		}
	}
}

type processIdentity struct {
	Hostname string `json:"hostname"`
	PID      int    `json:"pid"`
}

func (c *Coordinator) inspectProcessIdentity(ctx context.Context, pin isolation.PinnedResource) (processIdentity, error) {
	command, err := isolation.ResourcesInspectCommand(c.executable, []string{pin.ID})
	if err != nil {
		return processIdentity{}, err
	}
	stdout, _, code, err := c.runner.Run(ctx, command)
	if err != nil || code != 0 {
		return processIdentity{}, fmt.Errorf("%w: runtime process identity inspection failed", ErrUnavailable)
	}
	var docs []struct {
		ID     string `json:"Id"`
		Config struct {
			Hostname string `json:"Hostname"`
		} `json:"Config"`
		State struct {
			Running bool `json:"Running"`
			PID     int  `json:"Pid"`
		} `json:"State"`
	}
	if err := json.Unmarshal(stdout, &docs); err != nil || len(docs) != 1 || docs[0].ID != pin.ID || !docs[0].State.Running || docs[0].Config.Hostname == "" || docs[0].State.PID <= 0 {
		return processIdentity{}, fmt.Errorf("%w: runtime container host identity is incomplete", ErrPrecondition)
	}
	// State.Pid is the host PID. The pinned runtime policy does not enable
	// host PID sharing, and the container entrypoint is exec'd as PID 1.
	return processIdentity{Hostname: docs[0].Config.Hostname, PID: 1}, nil
}

func (c *Coordinator) validateStores(pin isolation.PinnedResource, snapshots []OfflineStoreSnapshot) (OfflineStoreEvidence, error) {
	if len(snapshots) != 3 {
		return OfflineStoreEvidence{}, ErrPrecondition
	}
	wantStore := map[string]bool{"application": true, "comet-state": true, "block-store": true}
	snapshots = append([]OfflineStoreSnapshot(nil), snapshots...)
	sort.Slice(snapshots, func(i, j int) bool { return snapshots[i].Store < snapshots[j].Store })
	out := OfflineStoreEvidence{Snapshots: make([]OfflineStoreSnapshot, 0, len(snapshots)), Digests: map[string]string{}}
	for _, item := range snapshots {
		if !wantStore[item.Store] || item.SchemaVersion != contract.Version || item.RunID != c.binding.RunID || item.BindingDigest != c.bindingDigest || item.NodeID != c.plan.NodeID || item.RuntimeID != pin.ID || item.Height != c.plan.Barrier.Height || item.AppHash != c.plan.Barrier.AppHash || item.BlockID != strings.ToUpper(c.plan.Barrier.BlockHash) || item.PartSetHash != strings.ToUpper(c.plan.Barrier.PartSetHash) || item.PartSetTotal != c.plan.Barrier.PartSetTotal || len(item.RawSnapshot) == 0 || len(item.RawSnapshot) > 64<<20 {
			return OfflineStoreEvidence{}, ErrPrecondition
		}
		if _, duplicate := out.Digests[item.Store]; duplicate {
			return OfflineStoreEvidence{}, ErrPrecondition
		}
		var snapshot contract.Snapshot
		if err := contract.DecodeStrict(item.RawSnapshot, &snapshot); err != nil {
			return OfflineStoreEvidence{}, ErrPrecondition
		}
		_, err := evidence.SnapshotDigest(snapshot)
		if err != nil {
			return OfflineStoreEvidence{}, err
		}
		out.Digests[item.Store] = contract.PayloadDigest(item.RawSnapshot)
		item.RawSnapshot = append([]byte(nil), item.RawSnapshot...)
		out.Snapshots = append(out.Snapshots, item)
		delete(wantStore, item.Store)
	}
	if len(wantStore) != 0 {
		return OfflineStoreEvidence{}, ErrPrecondition
	}
	return out, nil
}

func (c *Coordinator) mutate(ctx context.Context, step Step, intent any, action func() (any, error)) error {
	intentRaw, err := json.Marshal(intent)
	if err != nil {
		return err
	}
	if err := c.journal.Begin(ctx, c.bindingDigest, step, intentRaw); err != nil {
		return fmt.Errorf("%w: begin %s: %v", ErrJournal, step, err)
	}
	out, err := action()
	if err != nil {
		_ = c.journal.Unknown(ctx, c.bindingDigest, step, err.Error())
		return fmt.Errorf("%w: %v", ErrUnknown, err)
	}
	resultRaw, err := json.Marshal(out)
	if err != nil {
		_ = c.journal.Unknown(ctx, c.bindingDigest, step, err.Error())
		return ErrUnknown
	}
	if err := c.journal.Complete(ctx, c.bindingDigest, step, resultRaw); err != nil {
		_ = c.journal.Unknown(ctx, c.bindingDigest, step, "runtime effect completed but result receipt could not be persisted")
		return fmt.Errorf("%w: complete %s: %v", ErrUnknown, step, err)
	}
	return nil
}

func (c *Coordinator) record(ctx context.Context, step Step, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := c.journal.Record(ctx, c.bindingDigest, step, raw); err != nil {
		return fmt.Errorf("%w: record %s: %v", ErrJournal, step, err)
	}
	return nil
}

func (c *Coordinator) readLedger(ctx context.Context) (Ledger, error) {
	ledger, err := c.journal.Read(ctx, c.bindingDigest)
	if err != nil {
		return Ledger{}, fmt.Errorf("%w: read durable ledger: %v", ErrJournal, err)
	}
	if ledger.BindingDigest != c.bindingDigest {
		return Ledger{}, ErrPrecondition
	}
	if ledger.Unknown || ledger.Pending != nil {
		return Ledger{}, ErrUnknown
	}
	if len(ledger.Completed) > len(orderedSteps) {
		return Ledger{}, ErrPrecondition
	}
	for i, record := range ledger.Completed {
		if record.Step != orderedSteps[i] || len(record.Evidence) == 0 {
			return Ledger{}, ErrPrecondition
		}
		if record.Step == ControlCreate || record.Step == RecoveryCreate || record.Step == StandardCreate {
			var pin isolation.PinnedResource
			if contract.DecodeStrict(record.Evidence, &pin) != nil || !c.validPinnedForStep(record.Step, pin) {
				return Ledger{}, ErrPrecondition
			}
		}
	}
	return ledger, nil
}

func (c *Coordinator) validPinnedForStep(step Step, pin isolation.PinnedResource) bool {
	want := c.plan.Control
	switch step {
	case ControlCreate:
		want = c.plan.Control
	case RecoveryCreate:
		want = c.plan.Recovery
	case StandardCreate:
		want = c.plan.Standard
	default:
		return false
	}
	return pin.ID != "" && pin.Name == want.Name && pin.Image == want.Image && pin.RunID == c.binding.RunID && pin.OwnershipMarker == c.binding.OwnershipMarker && pin.BindingDigest == c.bindingDigest && pin.SelectedBinaryRole == want.SelectedBinaryRole && pin.SelectedBinaryPath == c.binding.Paths[string(want.SelectedBinaryRole)+"-binary"] && pin.SelectedBinaryDigest == c.binding.InputDigests[string(want.SelectedBinaryRole)+"-binary"] && pin.ForkKey == selectedFork(want) && pin.Network == nil && len(pin.Ports) == 0 && reflect.DeepEqual(pin.Argv, want.Argv) && reflect.DeepEqual(pin.Entrypoint, want.Entrypoint) && reflect.DeepEqual(pin.Environment, want.Environment) && reflect.DeepEqual(pin.DNSAliases, want.DNSAliases) && reflect.DeepEqual(pin.Ports, want.Ports) && pin.ForkTarget == want.ForkTarget
}

func findEvidence[T any](ledger Ledger, step Step) (T, error) {
	var zero T
	for _, record := range ledger.Completed {
		if record.Step == step {
			var out T
			if err := contract.DecodeStrict(record.Evidence, &out); err != nil {
				return zero, ErrPrecondition
			}
			return out, nil
		}
	}
	return zero, ErrPrecondition
}

func findPin[T any](ledger Ledger, step Step) (T, error) {
	var zero T
	if step == ControlCreate || step == RecoveryCreate || step == StandardCreate {
		return findEvidence[T](ledger, step)
	}
	return zero, ErrPrecondition
}

func (c *Coordinator) resultFromLedger(ledger Ledger) (Result, error) {
	control, err := findPin[isolation.PinnedResource](ledger, ControlCreate)
	if err != nil {
		return Result{}, err
	}
	recovery, err := findPin[isolation.PinnedResource](ledger, RecoveryCreate)
	if err != nil {
		return Result{}, err
	}
	standard, err := findPin[isolation.PinnedResource](ledger, StandardCreate)
	if err != nil {
		return Result{}, err
	}
	barrier, err := findEvidence[barrierReceipt](ledger, BarrierValidated)
	if err != nil {
		return Result{}, err
	}
	hplus, err := findEvidence[hplusReceipt](ledger, HPlusOneCollected)
	if err != nil {
		return Result{}, err
	}
	return Result{ControlPin: control, RecoveryPin: recovery, StandardPin: standard, Barrier: barrier.Marker, HPlusOne: hplus.Verification}, nil
}

func selectedFork(spec isolation.ContainerSpec) string {
	for _, mount := range spec.Mounts {
		if mount.PathKey == "fork-a" || mount.PathKey == "fork-b" {
			return mount.PathKey
		}
	}
	return ""
}

func barrierFilename(stage coregate.BarrierStage, height int64) string {
	return fmt.Sprintf("barrier-%s-%d.json", stage, height)
}

func readBoundMarker(rootPath, filename string) ([]byte, time.Time, error) {
	if filepath.Base(filename) != filename || filename == "." || filename == ".." {
		return nil, time.Time{}, ErrPrecondition
	}
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer root.Close()
	dir, err := root.OpenRoot("gnklab0002-recovery-barrier")
	if err != nil {
		return nil, time.Time{}, err
	}
	defer dir.Close()
	info, err := dir.Lstat(filename)
	if err != nil {
		return nil, time.Time{}, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() <= 0 || info.Size() > 16<<10 {
		return nil, time.Time{}, ErrPrecondition
	}
	f, err := dir.OpenFile(filename, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, (16<<10)+1))
	if err != nil || int64(len(raw)) != info.Size() || len(raw) > 16<<10 {
		return nil, time.Time{}, ErrPrecondition
	}
	return raw, info.ModTime(), nil
}

func cloneBinding(b contract.RunBinding) contract.RunBinding {
	out := b
	out.Paths = cloneMap(b.Paths)
	out.InputDigests = cloneMap(b.InputDigests)
	out.RuntimeIdentities = cloneMap(b.RuntimeIdentities)
	if b.Heights.Consensus != nil {
		h := *b.Heights.Consensus
		out.Heights.Consensus = &h
	}
	return out
}

func nilLike(value any) bool {
	if value == nil {
		return true
	}
	v := reflect.ValueOf(value)
	switch v.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return v.IsNil()
	default:
		return false
	}
}

func cloneMap(in map[string]string) map[string]string {
	out := make(map[string]string, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}
