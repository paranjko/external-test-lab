//go:build linux

package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/lifecycle"
	"golang.org/x/sys/unix"
)

// ExecuteStage journals the stage mutation only after confirming the exact
// successful Capture predecessor, its full topology-before snapshot, and a
// read-only adapter preflight under the exclusive lifecycle lock.
func ExecuteStage(ctx context.Context, root, runID string, adapter StageAdapter) (contract.Receipt, error) {
	if ctx == nil || adapter == nil {
		return contract.Receipt{}, ErrPhaseAdapterUnavailable
	}
	return executePhase(ctx, root, runID, []phaseStep{{phase: contract.Capture, operation: "frozen_export_copy"}}, contract.Stage, "init", adapter.Preflight,
		func(ctx context.Context, binding contract.RunBinding) (map[string]contract.Snapshot, error) {
			after, err := adapter.ExecuteStage(ctx, binding)
			if err != nil {
				return nil, err
			}
			return map[string]contract.Snapshot{"topology.after": after}, nil
		})
}

// ExecuteRun journals the run mutation only after successful Capture and
// Stage predecessors and their bound snapshots have been revalidated.
func ExecuteRun(ctx context.Context, root, runID string, adapter RunAdapter) (contract.Receipt, error) {
	if ctx == nil || adapter == nil {
		return contract.Receipt{}, ErrPhaseAdapterUnavailable
	}
	return executePhase(ctx, root, runID, []phaseStep{{phase: contract.Capture, operation: "frozen_export_copy"}, {phase: contract.Stage, operation: "init"}}, contract.Run, "run", adapter.Preflight,
		func(ctx context.Context, binding contract.RunBinding) (map[string]contract.Snapshot, error) {
			out, err := adapter.ExecuteRun(ctx, binding)
			if err != nil {
				return nil, err
			}
			return map[string]contract.Snapshot{
				"migration.before": out.MigrationBefore, "migration.after": out.MigrationAfter,
				"block.before": out.BlockBefore, "block.after": out.BlockAfter,
			}, nil
		})
}

type phaseStep struct {
	phase     contract.Phase
	operation string
}

type phasePreflight func(context.Context, contract.RunBinding) error
type phaseMutation func(context.Context, contract.RunBinding) (map[string]contract.Snapshot, error)

func executePhase(ctx context.Context, root, runID string, predecessors []phaseStep, phase contract.Phase, operation string, preflight phasePreflight, mutation phaseMutation) (contract.Receipt, error) {
	if root == "" || runID == "" {
		return contract.Receipt{}, ErrPhasePrecondition
	}
	binding, state, revision, receipts, err := lifecycle.ReadStoredSnapshot(root)
	if err != nil || binding.Workspace != root || binding.RunID != runID || state != contract.Running {
		return contract.Receipt{}, fmt.Errorf("%w: run journal is absent, stale, or unknown", ErrPhasePrecondition)
	}
	if err := validatePhasePredecessors(receipts, predecessors); err != nil {
		return contract.Receipt{}, err
	}
	for _, step := range predecessors {
		if err := verifyPhaseSnapshots(root, receipts, step.phase); err != nil {
			return contract.Receipt{}, err
		}
	}
	if hasPhase(receipts, phase) {
		return contract.Receipt{}, fmt.Errorf("%w: phase already has a journal record", ErrPhasePrecondition)
	}
	journal, err := lifecycle.Open(root, binding)
	if err != nil {
		return contract.Receipt{}, fmt.Errorf("open exclusive run journal: %w", err)
	}
	defer journal.Close()
	lockedBinding, lockedState, lockedRevision, lockedReceipts := journal.Snapshot()
	if !sameBinding(binding, lockedBinding) || lockedState != state || lockedRevision != revision || !sameReceipts(receipts, lockedReceipts) || lockedState != contract.Running {
		return contract.Receipt{}, fmt.Errorf("%w: journal changed before preflight", ErrPhasePrecondition)
	}
	preflightBinding, err := cloneSnapshotBinding(binding)
	if err != nil {
		return contract.Receipt{}, fmt.Errorf("%w: cannot isolate adapter binding", ErrPhasePrecondition)
	}
	preflightDigest, _ := contract.Digest(preflightBinding)
	if err := preflight(ctx, preflightBinding); err != nil {
		return contract.Receipt{}, fmt.Errorf("%w: adapter preflight: %v", ErrPhasePrecondition, err)
	}
	if digest, digestErr := contract.Digest(preflightBinding); digestErr != nil || digest != preflightDigest {
		return contract.Receipt{}, fmt.Errorf("%w: adapter preflight mutated immutable binding", ErrPhasePrecondition)
	}
	// Preflight is contractually read-only. Re-read all predecessor snapshots
	// after it, so a buggy adapter cannot alter their bytes before intent.
	for _, step := range predecessors {
		if err := verifyPhaseSnapshots(root, lockedReceipts, step.phase); err != nil {
			return contract.Receipt{}, fmt.Errorf("%w: predecessor changed during preflight: %v", ErrPhasePrecondition, err)
		}
	}
	targetNames := phaseOutputNames(phase)
	if err := requireAbsentEvidenceFiles(root, targetNames); err != nil {
		return contract.Receipt{}, fmt.Errorf("%w: phase output already exists or is unsafe", ErrPhasePrecondition)
	}
	_, executeErr := journal.Execute(ctx, operation, contract.Receipt{Phase: phase}, phaseMutationAdapter{
		phase: phase, operation: operation, mutate: mutation, predecessors: predecessors, predecessorReceipts: lockedReceipts,
	})
	if executeErr != nil {
		_, currentState, _, currentReceipts := journal.Snapshot()
		if currentState == contract.Unknown || len(currentReceipts) > len(lockedReceipts) {
			if len(currentReceipts) > len(lockedReceipts) {
				return currentReceipts[len(currentReceipts)-1], fmt.Errorf("%w: %v", ErrPhaseExecutionUnknown, executeErr)
			}
			return contract.Receipt{}, fmt.Errorf("%w: %v", ErrPhaseExecutionUnknown, executeErr)
		}
		return contract.Receipt{}, executeErr
	}
	_, _, _, currentReceipts := journal.Snapshot()
	if len(currentReceipts) <= len(lockedReceipts) {
		return contract.Receipt{}, fmt.Errorf("%w: successful phase receipt missing", ErrPhaseExecutionUnknown)
	}
	return currentReceipts[len(currentReceipts)-1], nil
}

func validatePhasePredecessors(receipts []contract.Receipt, want []phaseStep) error {
	if len(receipts) != 2*len(want) {
		return fmt.Errorf("%w: producer phase history is incomplete or contains unrecognized phases", ErrPhasePrecondition)
	}
	for i, expected := range want {
		intent, result := receipts[2*i], receipts[2*i+1]
		if intent.Phase != expected.phase || result.Phase != expected.phase || intent.Operation != expected.operation || result.Operation != expected.operation || intent.State != contract.Running || result.State != contract.Succeeded {
			return fmt.Errorf("%w: expected terminal %s predecessor", ErrPhasePrecondition, expected.phase)
		}
	}
	return nil
}

func verifyPhaseSnapshots(root string, receipts []contract.Receipt, phase contract.Phase) error {
	result, ok := successfulPhase(receipts, phase)
	if !ok {
		return fmt.Errorf("%w: successful %s predecessor missing", ErrPhasePrecondition, phase)
	}
	keys := []string{}
	switch phase {
	case contract.Capture:
		keys = []string{"topology.before"}
	case contract.Stage:
		keys = []string{"topology.after"}
	default:
		return nil
	}
	for _, key := range keys {
		snapshot, err := readSnapshotFile(root, key)
		if err != nil {
			return fmt.Errorf("%w: pinned %s snapshot unavailable", ErrPhasePrecondition, key)
		}
		digest, err := evidence.SnapshotDigest(snapshot)
		if err != nil || result.EvidenceDigests[key] != digest {
			return fmt.Errorf("%w: %s snapshot digest mismatch", ErrPhasePrecondition, key)
		}
	}
	return nil
}

type phaseMutationAdapter struct {
	phase               contract.Phase
	operation           string
	mutate              phaseMutation
	predecessors        []phaseStep
	predecessorReceipts []contract.Receipt
}

func (a phaseMutationAdapter) Execute(ctx context.Context, binding contract.RunBinding, operation string) (contract.Receipt, error) {
	if operation != a.operation || a.mutate == nil {
		return contract.Receipt{}, errors.New("invalid phase mutation dispatch")
	}
	isolatedBinding, err := cloneSnapshotBinding(binding)
	if err != nil {
		return contract.Receipt{}, err
	}
	bindingDigest, _ := contract.Digest(isolatedBinding)
	snapshots, err := a.mutate(ctx, isolatedBinding)
	if err != nil {
		return contract.Receipt{}, err
	}
	if digest, digestErr := contract.Digest(isolatedBinding); digestErr != nil || digest != bindingDigest {
		return contract.Receipt{}, errors.New("phase adapter mutated immutable binding")
	}
	// The mutation callback may have replaced predecessor files while performing
	// its operation. Revalidate the receipt-pinned snapshots before reading their
	// store inventory or accepting any output.
	for _, step := range a.predecessors {
		if err := verifyPhaseSnapshots(binding.Workspace, a.predecessorReceipts, step.phase); err != nil {
			return contract.Receipt{}, fmt.Errorf("predecessor changed during phase mutation: %w", err)
		}
	}
	if len(snapshots) != len(phaseOutputNames(a.phase)) {
		return contract.Receipt{}, errors.New("phase adapter returned an incomplete snapshot set")
	}
	storeSet, err := snapshotStoreSetFromPredecessors(binding, a.phase)
	if err != nil {
		return contract.Receipt{}, err
	}
	files := make(map[string][]byte, len(snapshots))
	digests := make(map[string]string, len(snapshots))
	for key, snapshot := range snapshots {
		digest, err := evidence.SnapshotDigest(snapshot)
		if err != nil {
			return contract.Receipt{}, fmt.Errorf("invalid %s snapshot: %w", key, err)
		}
		if !sameSnapshotStoreSet(storeSet, snapshot) {
			return contract.Receipt{}, fmt.Errorf("%s snapshot store inventory differs from captured topology", key)
		}
		raw, err := json.Marshal(snapshot)
		if err != nil || len(raw) > maxFileSize {
			return contract.Receipt{}, fmt.Errorf("%s snapshot is not persistable", key)
		}
		files[snapshotFileName(key)] = append(raw, '\n')
		digests[key] = digest
	}
	if err := writeNewEvidenceFiles(binding.Workspace, files); err != nil {
		return contract.Receipt{}, fmt.Errorf("persist phase snapshots: %w", err)
	}
	return contract.Receipt{Phase: a.phase, Operation: a.operation, State: contract.Succeeded, EvidenceDigests: digests}, nil
}

func phaseOutputNames(phase contract.Phase) []string {
	switch phase {
	case contract.Stage:
		return []string{"snapshot-topology-after.json"}
	case contract.Run:
		return []string{"snapshot-migration-before.json", "snapshot-migration-after.json", "snapshot-block-before.json", "snapshot-block-after.json"}
	default:
		return nil
	}
}

func snapshotFileName(key string) string {
	return "snapshot-" + strings.ReplaceAll(key, ".", "-") + ".json"
}

func readSnapshotFile(root, key string) (contract.Snapshot, error) {
	raw, err := readOwnedFile(root, filepath.Join(root, "evidence", snapshotFileName(key)))
	if err != nil {
		return contract.Snapshot{}, err
	}
	var snapshot contract.Snapshot
	if err := contract.DecodeStrict(raw, &snapshot); err != nil {
		return snapshot, err
	}
	return snapshot, nil
}

func requireAbsentEvidenceFiles(root string, names []string) error {
	rootDir, err := openOwnedRoot(root)
	if err != nil {
		return err
	}
	defer rootDir.Close()
	evidenceDir, err := openEvidenceRoot(rootDir, false)
	if err != nil {
		return err
	}
	defer evidenceDir.Close()
	for _, name := range names {
		if filepath.Base(name) != name {
			return ErrInvalidSession
		}
		if _, err := evidenceDir.Lstat(name); err == nil || !errors.Is(err, os.ErrNotExist) {
			return errors.New("phase evidence target exists or cannot be inspected")
		}
	}
	return nil
}

func snapshotStoreSetFromPredecessors(binding contract.RunBinding, phase contract.Phase) ([]string, error) {
	var key string
	switch phase {
	case contract.Stage:
		key = "topology.before"
	case contract.Run:
		key = "topology.after"
	default:
		return nil, ErrPhasePrecondition
	}
	snapshot, err := readSnapshotFile(binding.Workspace, key)
	if err != nil {
		return nil, err
	}
	stores := make([]string, len(snapshot.Stores))
	for i, store := range snapshot.Stores {
		stores[i] = store.Name
	}
	return stores, nil
}

func sameSnapshotStoreSet(want []string, got contract.Snapshot) bool {
	if len(want) != len(got.Stores) {
		return false
	}
	seen := make(map[string]bool, len(want))
	for _, name := range want {
		seen[name] = true
	}
	for _, store := range got.Stores {
		if !seen[store.Name] {
			return false
		}
	}
	return true
}

func writeNewEvidenceFiles(root string, files map[string][]byte) error {
	if len(files) == 0 {
		return errors.New("no snapshot files")
	}
	rootDir, err := openOwnedRoot(root)
	if err != nil {
		return err
	}
	defer rootDir.Close()
	evidenceDir, err := openEvidenceRoot(rootDir, false)
	if err != nil {
		return err
	}
	defer evidenceDir.Close()
	for name, raw := range files {
		if filepath.Base(name) != name || len(raw) > maxFileSize {
			return errors.New("unsafe or oversized snapshot file")
		}
		file, err := evidenceDir.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0600)
		if err != nil {
			return err
		}
		if _, err := file.Write(raw); err != nil {
			file.Close()
			return err
		}
		if err := file.Sync(); err != nil {
			file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
	}
	dir, err := evidenceDir.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
