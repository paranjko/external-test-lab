package session

import (
	"context"
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

var (
	ErrPhaseAdapterUnavailable = errors.New("rehearsal phase adapter is unavailable")
	ErrPhasePrecondition       = errors.New("rehearsal phase predecessor or evidence precondition failed")
	ErrPhaseExecutionUnknown   = errors.New("rehearsal phase execution outcome is unknown")
)

// StageAdapter performs read-only preflight before mutation and returns the
// full post-stage topology snapshot. It cannot supply a receipt or verdict;
// the session layer validates and pins the snapshot itself.
type StageAdapter interface {
	Preflight(context.Context, contract.RunBinding) error
	ExecuteStage(context.Context, contract.RunBinding) (contract.Snapshot, error)
}

// RunSnapshots contains the full logical snapshots returned after one run
// phase. The caller never supplies phase receipts or PASS assertions.
type RunSnapshots struct {
	MigrationBefore contract.Snapshot
	MigrationAfter  contract.Snapshot
	BlockBefore     contract.Snapshot
	BlockAfter      contract.Snapshot
}

// RunAdapter performs read-only preflight before mutation and returns full
// logical snapshots. The session layer computes all persisted digests.
type RunAdapter interface {
	Preflight(context.Context, contract.RunBinding) error
	ExecuteRun(context.Context, contract.RunBinding) (RunSnapshots, error)
}
