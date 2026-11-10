// Package lifecycle provides crash-conservative local state for isolated
// recovery rehearsals. It does not start containers or contact a runtime.
package lifecycle

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"golang.org/x/sys/unix"
)

var (
	ErrUnsafePath  = errors.New("unsafe rehearsal lifecycle path")
	ErrConflict    = errors.New("rehearsal journal conflict")
	ErrQuarantined = errors.New("run is quarantined as unknown")
)

const journalName = "lifecycle.json"

type entry struct {
	Kind      string           `json:"kind"`
	Operation string           `json:"operation"`
	Receipt   contract.Receipt `json:"receipt"`
}

type document struct {
	Version       string              `json:"version"`
	Binding       contract.RunBinding `json:"binding"`
	BindingDigest string              `json:"binding_digest"`
	Revision      string              `json:"revision"`
	InitClaimed   bool                `json:"init_claimed"`
	State         contract.State      `json:"state"`
	Quarantined   bool                `json:"quarantined,omitempty"`
	Pending       *entry              `json:"pending,omitempty"`
	Entries       []entry             `json:"entries"`
}

// MutationAdapter is the only path from durable intent to a runtime action.
// Implementations are supplied by the caller; this package has no Docker
// implementation and performs no runtime operation itself.
type MutationAdapter interface {
	Execute(context.Context, contract.RunBinding, string) (contract.Receipt, error)
}

type CleanupAdapter = contract.CleanupAdapter

type Lifecycle struct {
	mu      sync.Mutex
	opMu    sync.Mutex
	fsRoot  *os.Root
	fileOps fileOps
	lock    *os.File
	doc     document
	closed  bool
}

// Open creates or opens the run journal while holding an exclusive process
// lock. The immutable binding is pinned on first creation and compared on all
// later opens. A pending mutation is quarantined immediately on reopen.
func Open(root string, binding contract.RunBinding) (*Lifecycle, error) {
	return openWithOps(root, binding, osFileOps{})
}

func openWithOps(root string, binding contract.RunBinding, ops fileOps) (*Lifecycle, error) {
	if err := validateRootBinding(root, binding); err != nil {
		return nil, err
	}
	if err := contract.ValidateBinding(binding); err != nil {
		return nil, fmt.Errorf("invalid run binding: %w", err)
	}
	fsRoot, err := ensurePrivateRoot(root)
	if err != nil {
		return nil, err
	}
	lockInfo, err := fsRoot.Lstat(".lifecycle.lock")
	if err == nil && (!lockInfo.Mode().IsRegular() || lockInfo.Mode()&os.ModeSymlink != 0 || !singleLink(lockInfo)) {
		fsRoot.Close()
		return nil, ErrUnsafePath
	}
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		fsRoot.Close()
		return nil, err
	}
	lock, err := fsRoot.OpenFile(".lifecycle.lock", os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		fsRoot.Close()
		return nil, err
	}
	lockInfo, err = lock.Stat()
	if err != nil || !lockInfo.Mode().IsRegular() || lockInfo.Mode().Perm()&0o077 != 0 || !singleLink(lockInfo) || !ownedByCurrentUser(lockInfo) {
		lock.Close()
		fsRoot.Close()
		return nil, ErrUnsafePath
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lock.Close()
		fsRoot.Close()
		return nil, fmt.Errorf("run is already open: %w", err)
	}
	l := &Lifecycle{fileOps: ops, lock: lock, fsRoot: fsRoot}
	journalInfo, statErr := fsRoot.Lstat(journalName)
	if statErr == nil && (!journalInfo.Mode().IsRegular() || journalInfo.Mode()&os.ModeSymlink != 0 || journalInfo.Mode().Perm()&0o077 != 0 || !singleLink(journalInfo) || !ownedByCurrentUser(journalInfo)) {
		l.Close()
		return nil, ErrUnsafePath
	}
	if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
		l.Close()
		return nil, statErr
	}
	raw, err := ops.read(fsRoot, journalName)
	if errors.Is(err, fs.ErrNotExist) {
		directory, readDirErr := fsRoot.Open(".")
		if readDirErr != nil {
			l.Close()
			return nil, readDirErr
		}
		contents, readDirErr := directory.ReadDir(-1)
		directory.Close()
		if readDirErr != nil {
			l.Close()
			return nil, readDirErr
		}
		for _, item := range contents {
			if item.Name() != ".lifecycle.lock" {
				l.Close()
				return nil, fmt.Errorf("refusing to adopt nonempty run directory: %w", ErrUnsafePath)
			}
		}
		digest, derr := contract.Digest(binding)
		if derr != nil {
			l.Close()
			return nil, derr
		}
		binding, derr = cloneBinding(binding)
		if derr != nil {
			l.Close()
			return nil, derr
		}
		l.doc = document{Version: contract.Version, Binding: binding, BindingDigest: digest, State: contract.Planned}
		if err := ops.beforePersist(); err != nil {
			l.Close()
			return nil, err
		}
		if err := l.persist(nil); err != nil {
			l.Close()
			return nil, err
		}
		return l, nil
	}
	if err != nil {
		l.Close()
		return nil, err
	}
	var d document
	if err := contract.DecodeStrict(raw, &d); err != nil {
		l.Close()
		return nil, fmt.Errorf("decode lifecycle journal: %w", err)
	}
	want, err := contract.Digest(binding)
	if err != nil {
		l.Close()
		return nil, err
	}
	if d.Version != contract.Version || d.BindingDigest != want || d.BindingDigest != mustDigest(d.Binding) {
		l.Close()
		return nil, ErrConflict
	}
	storedRevision := d.Revision
	d.Revision = ""
	actualRevision, err := digestDocument(d)
	d.Revision = storedRevision
	if err != nil || storedRevision == "" || actualRevision != storedRevision {
		l.Close()
		return nil, ErrConflict
	}
	l.doc = d
	if err := validateJournal(d); err != nil {
		l.Close()
		return nil, err
	}
	// A crash after the one-shot init claim but before its explicit result is
	// indistinguishable from an interrupted init. Synthesize the unresolved
	// intent in memory so the durable transition below quarantines it as unknown.
	if l.doc.Pending == nil && l.doc.InitClaimed && l.doc.State == contract.Running && !operationRecorded(l.doc.Entries, "init") {
		claim := entry{Kind: "intent", Operation: "init", Receipt: contract.Receipt{
			SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: want,
			Phase: contract.Stage, Operation: "init", State: contract.Running,
			Sequence: uint64(len(l.doc.Entries) + 1), Predecessor: previousReceiptDigest(l.doc.Entries),
		}}
		l.doc.Pending = &claim
		l.doc.Entries = append(l.doc.Entries, claim)
	}
	if l.doc.Pending != nil {
		pending := *l.doc.Pending
		pending.Kind = "result"
		pending.Receipt.State = contract.Unknown
		pending.Receipt.Reason = "process ended after durable mutation intent; outcome requires read-only reconciliation"
		pending.Receipt.Sequence++
		pending.Receipt.Predecessor = receiptDigest(l.doc.Pending.Receipt)
		pending.Receipt.ExitCode = nil
		l.doc.Entries = append(l.doc.Entries, pending)
		l.doc.Pending = nil
		l.doc.Quarantined = true
		if pending.Operation != "cleanup" {
			l.doc.State = contract.Unknown
		}
		if err := l.persist(&d.Revision); err != nil {
			l.Close()
			return nil, err
		}
	}
	if err := syncRoot(l.fsRoot); err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}

func validateRootBinding(root string, b contract.RunBinding) error {
	if root == "" || !filepath.IsAbs(root) || filepath.Clean(root) != root || root == "/" || b.RunID == "" || b.Workspace != root || b.OwnershipMarker == "" || b.SchemaVersion != contract.Version {
		return ErrUnsafePath
	}
	if strings.ContainsAny(b.RunID, `/\\`) || b.RunID == "." || b.RunID == ".." {
		return ErrUnsafePath
	}
	return nil
}

// ClaimInit atomically and durably claims the run's sole initialization.
func (l *Lifecycle) ClaimInit() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.ready(); err != nil {
		return err
	}
	return l.claimInitLocked()
}

func (l *Lifecycle) claimInitLocked() error {
	if l.doc.InitClaimed || l.doc.Pending != nil || (l.doc.State != contract.Planned && l.doc.State != contract.Running) || operationRecorded(l.doc.Entries, "init") {
		return ErrConflict
	}
	if l.doc.State == contract.Planned && !contract.CanTransition(l.doc.State, contract.Running) {
		return ErrConflict
	}
	if err := l.fileOps.beforePersist(); err != nil {
		return err
	}
	old := l.doc.Revision
	l.doc.InitClaimed = true
	l.doc.State = contract.Running
	return l.persist(&old)
}

// RecordIntent persists an intent before callers invoke a mutation adapter.
// Only one unresolved intent can exist at a time.
func (l *Lifecycle) RecordIntent(operation string, receipt contract.Receipt) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.ready(); err != nil {
		return err
	}
	if operation == "" || l.doc.Pending != nil || l.doc.State == contract.Unknown {
		return ErrConflict
	}
	if receipt.Operation != "" && receipt.Operation != operation {
		return ErrConflict
	}
	if operation == "init" {
		if !l.doc.InitClaimed {
			if err := l.claimInitLocked(); err != nil {
				return err
			}
		}
		if operationRecorded(l.doc.Entries, "init") {
			return ErrConflict
		}
	} else if l.doc.InitClaimed && !operationCompleted(l.doc.Entries, "init") {
		return ErrConflict
	}
	if l.doc.State == contract.Succeeded || l.doc.State == contract.Failed || l.doc.State == contract.Blocked {
		if operation != "cleanup" || l.doc.State != contract.Succeeded || cleanupRecorded(l.doc.Entries) {
			return ErrConflict
		}
	} else if operation == "cleanup" {
		return ErrConflict
	}
	if err := l.fileOps.beforePersist(); err != nil {
		return err
	}
	receipt, err := cloneReceipt(receipt)
	if err != nil {
		return err
	}
	receipt.State = contract.Running
	if err := bindReceipt(&receipt, l.doc, operation); err != nil {
		return err
	}
	if l.doc.State == contract.Planned {
		if !contract.CanTransition(l.doc.State, contract.Running) {
			return ErrConflict
		}
		l.doc.State = contract.Running
	}
	old := l.doc.Revision
	intent := entry{Kind: "intent", Operation: operation, Receipt: receipt}
	l.doc.Entries = append(l.doc.Entries, intent)
	l.doc.Pending = &intent
	return l.persist(&old)
}

// RecordResult completes the pending mutation after the adapter returns. If
// persistence fails, reopen will conservatively convert the intent to unknown.
func (l *Lifecycle) RecordResult(receipt contract.Receipt) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.ready(); err != nil {
		return err
	}
	if l.doc.Pending == nil {
		return ErrConflict
	}
	if err := l.fileOps.beforePersist(); err != nil {
		return err
	}
	receipt, err := cloneReceipt(receipt)
	if err != nil {
		return err
	}
	op := l.doc.Pending.Operation
	if receipt.Operation != "" && receipt.Operation != op {
		return ErrConflict
	}
	if receipt.Phase != l.doc.Pending.Receipt.Phase {
		return ErrConflict
	}
	if err := bindReceipt(&receipt, l.doc, op); err != nil {
		return err
	}
	if receipt.State != contract.Succeeded && receipt.State != contract.Failed && receipt.State != contract.Blocked {
		return ErrConflict
	}
	receipt.Sequence = l.doc.Pending.Receipt.Sequence + 1
	receipt.Predecessor = receiptDigest(l.doc.Pending.Receipt)
	old := l.doc.Revision
	l.doc.Entries = append(l.doc.Entries, entry{Kind: "result", Operation: op, Receipt: receipt})
	l.doc.Pending = nil
	if op == "cleanup" {
		if receipt.State == contract.Succeeded {
			l.doc.State = contract.Succeeded
		} else {
			l.doc.State = contract.Succeeded
			l.doc.Quarantined = true
		}
	} else if receipt.State == contract.Failed || receipt.State == contract.Blocked {
		l.doc.State = receipt.State
	} else {
		l.doc.State = contract.Running
	}
	return l.persist(&old)
}

// Execute journals the intent before calling the injected adapter and journals
// its result afterwards. Any error after intent remains recoverable as unknown.
func (l *Lifecycle) Execute(ctx context.Context, operation string, intent contract.Receipt, adapter MutationAdapter) (contract.Receipt, error) {
	l.opMu.Lock()
	defer l.opMu.Unlock()
	if adapter == nil || ctx == nil {
		return contract.Receipt{}, ErrConflict
	}
	if err := l.RecordIntent(operation, intent); err != nil {
		return contract.Receipt{}, err
	}
	l.mu.Lock()
	binding, cloneErr := cloneBinding(l.doc.Binding)
	l.mu.Unlock()
	if cloneErr != nil {
		return contract.Receipt{}, cloneErr
	}
	result, callErr := adapter.Execute(ctx, binding, operation)
	if callErr != nil {
		result.State = contract.Unknown
		result.Reason = "adapter returned an error after intent; outcome requires read-only reconciliation: " + callErr.Error()
		if err := l.quarantine(result); err != nil {
			return result, errors.Join(callErr, err)
		}
		return result, callErr
	}
	if err := l.RecordResult(result); err != nil {
		return result, err
	}
	return result, nil
}

// Reconcile records read-only evidence while preserving Unknown. It never
// clears the quarantine or authorizes another mutation.
func (l *Lifecycle) Reconcile(r contract.Receipt) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l == nil || l.closed || l.lock == nil {
		return ErrConflict
	}
	if l.doc.State != contract.Unknown && !l.doc.Quarantined {
		return ErrConflict
	}
	if err := l.fileOps.beforePersist(); err != nil {
		return err
	}
	r, err := cloneReceipt(r)
	if err != nil {
		return err
	}
	r.State = contract.Unknown
	if err := bindReceipt(&r, l.doc, "reconcile"); err != nil {
		return err
	}
	old := l.doc.Revision
	l.doc.Entries = append(l.doc.Entries, entry{Kind: "reconciliation", Operation: "reconcile", Receipt: r})
	return l.persist(&old)
}

// Cleanup requires a terminal successful run and adapter-confirmed ownership.
// The adapter is responsible for deleting only resources named by the binding.
func (l *Lifecycle) Cleanup(ctx context.Context, adapter CleanupAdapter) (contract.Receipt, error) {
	l.opMu.Lock()
	defer l.opMu.Unlock()
	if adapter == nil || ctx == nil {
		return contract.Receipt{}, ErrConflict
	}
	l.mu.Lock()
	if err := l.ready(); err != nil {
		l.mu.Unlock()
		return contract.Receipt{}, err
	}
	if l.doc.State != contract.Succeeded || l.doc.Pending != nil {
		l.mu.Unlock()
		return contract.Receipt{}, ErrConflict
	}
	if err := l.fileOps.beforePersist(); err != nil {
		l.mu.Unlock()
		return contract.Receipt{}, err
	}
	binding, cloneErr := cloneBinding(l.doc.Binding)
	if cloneErr != nil {
		l.mu.Unlock()
		return contract.Receipt{}, cloneErr
	}
	digest := l.doc.BindingDigest
	l.mu.Unlock()
	if err := adapter.ValidateOwnership(ctx, binding); err != nil {
		return contract.Receipt{}, fmt.Errorf("cleanup ownership refused: %w", err)
	}
	intent := contract.Receipt{SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: digest, Phase: contract.Cleanup, Operation: "cleanup", State: contract.Running}
	if err := l.RecordIntent("cleanup", intent); err != nil {
		return contract.Receipt{}, err
	}
	result, err := adapter.Cleanup(ctx, binding)
	if err != nil {
		result.State = contract.Unknown
		result.Reason = "cleanup outcome unknown; resources preserved pending reconciliation: " + err.Error()
		_ = l.quarantine(result)
		return result, err
	}
	if result.State != contract.Succeeded {
		return result, ErrConflict
	}
	if err := l.RecordResult(result); err != nil {
		return result, err
	}
	return result, nil
}

func (l *Lifecycle) Snapshot() (contract.RunBinding, contract.State, string, []contract.Receipt) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entries := make([]contract.Receipt, 0, len(l.doc.Entries))
	for _, e := range l.doc.Entries {
		raw, _ := json.Marshal(e.Receipt)
		var copied contract.Receipt
		_ = json.Unmarshal(raw, &copied)
		entries = append(entries, copied)
	}
	binding, _ := cloneBinding(l.doc.Binding)
	return binding, l.doc.State, l.doc.Revision, entries
}

func (l *Lifecycle) quarantine(r contract.Receipt) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.doc.Pending == nil {
		return ErrConflict
	}
	old := l.doc.Revision
	pending := *l.doc.Pending
	if copied, err := cloneReceipt(r); err == nil {
		r = copied
	}
	r.Phase = pending.Receipt.Phase
	r.SchemaVersion = contract.Version
	r.RunID = l.doc.Binding.RunID
	r.BindingDigest = l.doc.BindingDigest
	r.Operation = pending.Operation
	r.State = contract.Unknown
	r.Sequence = l.doc.Pending.Receipt.Sequence + 1
	r.Predecessor = receiptDigest(l.doc.Pending.Receipt)
	if err := contract.ValidateReceipt(r, l.doc.Binding); err != nil {
		r = pending.Receipt
		r.State = contract.Unknown
		r.Reason = "mutation outcome unknown; adapter result was invalid"
		r.Sequence = pending.Receipt.Sequence + 1
		r.Predecessor = receiptDigest(pending.Receipt)
	}
	l.doc.Entries = append(l.doc.Entries, entry{Kind: "result", Operation: l.doc.Pending.Operation, Receipt: r})
	l.doc.Pending = nil
	l.doc.Quarantined = true
	if pending.Operation != "cleanup" {
		l.doc.State = contract.Unknown
	}
	return l.persist(&old)
}

func (l *Lifecycle) ready() error {
	if l == nil || l.closed || l.lock == nil {
		return ErrConflict
	}
	if l.doc.State == contract.Unknown || l.doc.Quarantined {
		return ErrQuarantined
	}
	return nil
}

func bindReceipt(r *contract.Receipt, d document, operation string) error {
	if r.RunID != "" && r.RunID != d.Binding.RunID || r.BindingDigest != "" && r.BindingDigest != d.BindingDigest {
		return ErrConflict
	}
	r.SchemaVersion = contract.Version
	r.RunID = d.Binding.RunID
	r.BindingDigest = d.BindingDigest
	r.Operation = operation
	r.Sequence = uint64(len(d.Entries) + 1)
	r.Predecessor = previousReceiptDigest(d.Entries)
	return contract.ValidateReceipt(*r, d.Binding)
}

func (l *Lifecycle) persist(expected *string) (retErr error) {
	defer func() {
		if retErr != nil {
			l.doc.Quarantined = true
			if l.doc.State == contract.Running {
				l.doc.State = contract.Unknown
			}
		}
	}()
	if expected != nil && l.doc.Revision != *expected {
		return ErrConflict
	}
	current, readErr := l.fileOps.read(l.fsRoot, journalName)
	if expected == nil {
		if readErr == nil || !errors.Is(readErr, fs.ErrNotExist) {
			return ErrConflict
		}
	} else {
		if readErr != nil {
			return ErrConflict
		}
		var onDisk document
		if err := contract.DecodeStrict(current, &onDisk); err != nil || onDisk.Revision != *expected {
			return ErrConflict
		}
	}
	prior := l.doc.Revision
	without := l.doc
	without.Revision = ""
	digest, err := digestDocument(without)
	if err != nil {
		return err
	}
	l.doc.Revision = digest
	b, err := json.Marshal(l.doc)
	if err != nil {
		l.doc.Revision = prior
		return err
	}
	if err := atomicWrite(l.fileOps, l.fsRoot, journalName, b); err != nil {
		l.doc.Revision = prior
		l.doc.State = contract.Unknown
		return err
	}
	return nil
}

func cleanupRecorded(entries []entry) bool {
	for _, e := range entries {
		if e.Operation == "cleanup" {
			return true
		}
	}
	return false
}

func operationRecorded(entries []entry, operation string) bool {
	for _, e := range entries {
		if e.Operation == operation {
			return true
		}
	}
	return false
}
func operationCompleted(entries []entry, operation string) bool {
	for _, e := range entries {
		if e.Kind == "result" && e.Operation == operation && e.Receipt.State == contract.Succeeded {
			return true
		}
	}
	return false
}
func receiptDigest(r contract.Receipt) string { d, _ := contract.Digest(r); return d }
func previousReceiptDigest(entries []entry) string {
	if len(entries) == 0 {
		return ""
	}
	return receiptDigest(entries[len(entries)-1].Receipt)
}

func cloneReceipt(r contract.Receipt) (contract.Receipt, error) {
	raw, err := json.Marshal(r)
	if err != nil {
		return contract.Receipt{}, err
	}
	var out contract.Receipt
	err = json.Unmarshal(raw, &out)
	return out, err
}

func validateJournal(d document) error {
	previous := ""
	var unresolved *entry
	for i, e := range d.Entries {
		if e.Operation == "" || e.Receipt.Operation != e.Operation || e.Receipt.Sequence != uint64(i+1) || e.Receipt.Predecessor != previous {
			return ErrConflict
		}
		if err := contract.ValidateReceipt(e.Receipt, d.Binding); err != nil {
			return fmt.Errorf("invalid lifecycle receipt %d: %w", i+1, err)
		}
		switch e.Kind {
		case "intent":
			if unresolved != nil {
				return ErrConflict
			}
			copyEntry := e
			unresolved = &copyEntry
		case "result":
			if unresolved == nil || unresolved.Operation != e.Operation || unresolved.Receipt.Phase != e.Receipt.Phase {
				return ErrConflict
			}
			unresolved = nil
		case "reconciliation", "final":
			if unresolved != nil {
				return ErrConflict
			}
		default:
			return ErrConflict
		}
		previous = receiptDigest(e.Receipt)
	}
	if d.Pending != nil {
		if d.Pending.Kind != "intent" || len(d.Entries) == 0 || unresolved == nil {
			return ErrConflict
		}
		last := d.Entries[len(d.Entries)-1]
		if last.Kind != "intent" || last.Operation != d.Pending.Operation || receiptDigest(last.Receipt) != receiptDigest(d.Pending.Receipt) || unresolved.Operation != d.Pending.Operation {
			return ErrConflict
		}
	} else if unresolved != nil {
		return ErrConflict
	}
	if d.State != contract.Planned && d.State != contract.Running && d.State != contract.Succeeded && d.State != contract.Failed && d.State != contract.Blocked && d.State != contract.Unknown {
		return ErrConflict
	}
	return nil
}

// Finalize records the run-level verdict after required operations complete.
func (l *Lifecycle) Finalize(r contract.Receipt) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.ready(); err != nil {
		return err
	}
	if l.doc.State != contract.Running || l.doc.Pending != nil || !contract.CanTransition(l.doc.State, contract.Succeeded) {
		return ErrConflict
	}
	completed := false
	for _, e := range l.doc.Entries {
		if e.Kind == "result" {
			if e.Receipt.State == contract.Failed || e.Receipt.State == contract.Blocked || e.Receipt.State == contract.Unknown {
				return ErrConflict
			}
			if e.Receipt.State == contract.Succeeded {
				completed = true
			}
		}
	}
	if !completed {
		return ErrConflict
	}
	if err := l.fileOps.beforePersist(); err != nil {
		return err
	}
	r, err := cloneReceipt(r)
	if err != nil {
		return err
	}
	r.State = contract.Succeeded
	if err := bindReceipt(&r, l.doc, "finalize"); err != nil {
		return err
	}
	old := l.doc.Revision
	l.doc.Entries = append(l.doc.Entries, entry{Kind: "final", Operation: "finalize", Receipt: r})
	l.doc.State = contract.Succeeded
	return l.persist(&old)
}

func digestDocument(d document) (string, error) {
	b, err := json.Marshal(d)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}
func mustDigest(v any) string { d, _ := contract.Digest(v); return d }

func (l *Lifecycle) Close() error {
	if l == nil {
		return nil
	}
	l.opMu.Lock()
	defer l.opMu.Unlock()
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	if l.lock == nil {
		return nil
	}
	err := unix.Flock(int(l.lock.Fd()), unix.LOCK_UN)
	closeErr := l.lock.Close()
	l.lock = nil
	rootErr := l.fsRoot.Close()
	l.fsRoot = nil
	return errors.Join(err, closeErr, rootErr)
}
