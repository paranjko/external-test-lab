//go:build linux

package driver

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"syscall"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/isolation"
	"golang.org/x/sys/unix"
)

const (
	fsJournalName = ".gnklab0002-driver.jsonl"
	fsLockName    = ".gnklab0002-driver.lock"
	maxJournal    = 64 << 20
	fsSchema      = "rehearsal-driver-journal/v1"
)

var journalResourceName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$`)

type fsEvent struct {
	Schema        string          `json:"schema"`
	BindingDigest string          `json:"binding_digest"`
	Sequence      uint64          `json:"sequence"`
	Previous      string          `json:"previous"`
	Kind          string          `json:"kind"`
	Step          Step            `json:"step"`
	Evidence      json.RawMessage `json:"evidence,omitempty"`
	Reason        string          `json:"reason,omitempty"`
	Hash          string          `json:"hash"`
}

type fsEventPayload struct {
	Schema        string          `json:"schema"`
	BindingDigest string          `json:"binding_digest"`
	Sequence      uint64          `json:"sequence"`
	Previous      string          `json:"previous"`
	Kind          string          `json:"kind"`
	Step          Step            `json:"step"`
	Evidence      json.RawMessage `json:"evidence,omitempty"`
	Reason        string          `json:"reason,omitempty"`
}

// FSJournal is a run-workspace-owned, append-only, fsynced journal. Keep one
// instance open for the duration of a driver invocation; flock excludes other
// processes that could otherwise append concurrently.
type FSJournal struct {
	mu               sync.Mutex
	root             *os.Root
	file             *os.File
	lock             *os.File
	digest           string
	binding          contract.RunBinding
	closed           bool
	recoveredPending bool
}

// OpenFSJournal opens the driver ledger inside an already-existing bound run
// workspace. It never creates or replaces the workspace itself.
func OpenFSJournal(binding contract.RunBinding) (*FSJournal, error) {
	if err := contract.ValidateBinding(binding); err != nil {
		return nil, fmt.Errorf("invalid driver journal binding: %w", err)
	}
	digest, err := contract.Digest(binding)
	if err != nil {
		return nil, err
	}
	if err := checkFSJournalRoot(binding.Workspace); err != nil {
		return nil, fmt.Errorf("validate driver journal workspace: %w", err)
	}
	root, err := os.OpenRoot(binding.Workspace)
	if err != nil {
		return nil, err
	}
	closeRoot := true
	defer func() {
		if closeRoot {
			_ = root.Close()
		}
	}()
	lock, err := openSafeJournalFile(root, fsLockName, os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW)
	if err != nil {
		return nil, fmt.Errorf("open driver journal lock: %w", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lock.Close()
		return nil, fmt.Errorf("driver journal is already open: %w", err)
	}
	file, err := openSafeJournalFile(root, fsJournalName, os.O_CREATE|os.O_RDWR|os.O_APPEND|unix.O_NOFOLLOW)
	if err != nil {
		_ = unix.Flock(int(lock.Fd()), unix.LOCK_UN)
		_ = lock.Close()
		return nil, err
	}
	j := &FSJournal{root: root, file: file, lock: lock, digest: digest, binding: binding}
	if err := j.syncDirectory(); err != nil {
		_ = j.Close()
		return nil, fmt.Errorf("sync driver journal directory: %w", err)
	}
	ledger, err := j.readLocked()
	if err != nil {
		_ = j.Close()
		return nil, fmt.Errorf("read driver journal: %w", err)
	}
	j.recoveredPending = ledger.Pending != nil
	closeRoot = false
	return j, nil
}

func (j *FSJournal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return nil
	}
	j.closed = true
	var errs []error
	if j.file != nil {
		errs = append(errs, j.file.Close())
	}
	if j.lock != nil {
		errs = append(errs, unix.Flock(int(j.lock.Fd()), unix.LOCK_UN), j.lock.Close())
	}
	if j.root != nil {
		errs = append(errs, j.root.Close())
	}
	return errors.Join(errs...)
}

func (j *FSJournal) Read(ctx context.Context, digest string) (Ledger, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if err := j.usable(ctx, digest); err != nil {
		return Ledger{}, err
	}
	return j.readLocked()
}

func (j *FSJournal) Begin(ctx context.Context, digest string, step Step, evidence json.RawMessage) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if err := j.usable(ctx, digest); err != nil {
		return err
	}
	if j.recoveredPending {
		return ErrUnknown
	}
	ledger, err := j.readLocked()
	if err != nil {
		return err
	}
	if ledger.Unknown || ledger.Pending != nil || !nextStep(ledger, step) || !validEvidence(evidence) {
		return ErrPrecondition
	}
	return j.appendLocked("begin", step, evidence, "")
}

func (j *FSJournal) Complete(ctx context.Context, digest string, step Step, evidence json.RawMessage) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if err := j.usable(ctx, digest); err != nil {
		return err
	}
	if j.recoveredPending {
		return ErrUnknown
	}
	ledger, err := j.readLocked()
	if err != nil {
		return err
	}
	if ledger.Unknown || ledger.Pending == nil || *ledger.Pending != step || !validEvidence(evidence) {
		return ErrPrecondition
	}
	if isCreateStep(step) && !validCreatePin(evidence, j.binding, j.digest) {
		return ErrPrecondition
	}
	return j.appendLocked("complete", step, evidence, "")
}

func (j *FSJournal) Record(ctx context.Context, digest string, step Step, evidence json.RawMessage) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if err := j.usable(ctx, digest); err != nil {
		return err
	}
	if j.recoveredPending {
		return ErrUnknown
	}
	ledger, err := j.readLocked()
	if err != nil {
		return err
	}
	if ledger.Unknown || ledger.Pending != nil || !nextStep(ledger, step) || !validEvidence(evidence) {
		return ErrPrecondition
	}
	if isCreateStep(step) {
		return ErrPrecondition
	}
	return j.appendLocked("record", step, evidence, "")
}

func (j *FSJournal) Unknown(ctx context.Context, digest string, step Step, reason string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if err := j.usable(ctx, digest); err != nil {
		return err
	}
	if j.recoveredPending {
		return ErrUnknown
	}
	ledger, err := j.readLocked()
	if err != nil {
		return err
	}
	if ledger.Unknown || ledger.Pending == nil || *ledger.Pending != step || strings.TrimSpace(reason) == "" {
		return ErrPrecondition
	}
	return j.appendLocked("unknown", step, nil, reason)
}

// AuthorizeAdoption permits only the exact pin bytes from a durable completed
// Create entry in this binding's validated hash chain.
func (j *FSJournal) AuthorizeAdoption(ctx context.Context, pin isolation.PinnedResource) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed || ctx == nil || ctx.Err() != nil {
		return ErrPrecondition
	}
	ledger, err := j.readLocked()
	if err != nil || ledger.BindingDigest != j.digest || ledger.Pending != nil || ledger.Unknown {
		return ErrPrecondition
	}
	want, err := json.Marshal(pin)
	if err != nil || !validCreatePin(want, j.binding, j.digest) {
		return ErrPrecondition
	}
	for _, record := range ledger.Completed {
		if !isCreateStep(record.Step) {
			continue
		}
		if reflect.DeepEqual(record.Evidence, json.RawMessage(want)) {
			return nil
		}
	}
	return ErrPrecondition
}

func (j *FSJournal) usable(ctx context.Context, digest string) error {
	if j.closed || ctx == nil || ctx.Err() != nil || digest != j.digest {
		return ErrPrecondition
	}
	return nil
}

func (j *FSJournal) readLocked() (Ledger, error) {
	info, err := j.file.Stat()
	if err != nil || !safeJournalInfo(info) || info.Size() > maxJournal {
		return Ledger{}, ErrJournal
	}
	if _, err := j.file.Seek(0, io.SeekStart); err != nil {
		return Ledger{}, err
	}
	raw, err := io.ReadAll(io.LimitReader(j.file, maxJournal+1))
	if err != nil || len(raw) > maxJournal {
		return Ledger{}, ErrJournal
	}
	return replayJournal(raw, j.digest, j.binding)
}

func replayJournal(raw []byte, digest string, binding contract.RunBinding) (Ledger, error) {
	ledger := Ledger{BindingDigest: digest}
	previous := ""
	var pending *Step
	if len(raw) == 0 {
		return ledger, nil
	}
	if raw[len(raw)-1] != '\n' {
		return Ledger{}, fmt.Errorf("torn driver journal tail: %w", ErrJournal)
	}
	lines := strings.Split(string(raw[:len(raw)-1]), "\n")
	for i, line := range lines {
		if line == "" {
			return Ledger{}, ErrJournal
		}
		var event fsEvent
		if err := contract.DecodeStrict([]byte(line), &event); err != nil {
			return Ledger{}, fmt.Errorf("decode driver journal event %d: %w", i+1, err)
		}
		payload := fsEventPayload{event.Schema, event.BindingDigest, event.Sequence, event.Previous, event.Kind, event.Step, event.Evidence, event.Reason}
		encoded, err := json.Marshal(payload)
		if err != nil {
			return Ledger{}, err
		}
		sum := sha256.Sum256(encoded)
		wantHash := hex.EncodeToString(sum[:])
		if event.Schema != fsSchema || event.BindingDigest != digest || event.Sequence != uint64(i+1) || event.Previous != previous || event.Hash != wantHash {
			return Ledger{}, fmt.Errorf("driver journal chain mismatch at event %d: %w", i+1, ErrJournal)
		}
		if len(event.Evidence) > 0 && !validEvidence(event.Evidence) {
			return Ledger{}, ErrJournal
		}
		switch event.Kind {
		case "begin":
			if ledger.Unknown || pending != nil || !nextStep(ledger, event.Step) || event.Reason != "" || len(event.Evidence) == 0 {
				return Ledger{}, ErrJournal
			}
			s := event.Step
			pending = &s
		case "complete":
			if ledger.Unknown || pending == nil || *pending != event.Step || event.Reason != "" || len(event.Evidence) == 0 {
				return Ledger{}, ErrJournal
			}
			if isCreateStep(event.Step) && !validCreatePin(event.Evidence, binding, digest) {
				return Ledger{}, ErrJournal
			}
			ledger.Completed = append(ledger.Completed, Record{Step: event.Step, Evidence: append(json.RawMessage(nil), event.Evidence...)})
			pending = nil
		case "record":
			if ledger.Unknown || pending != nil || !nextStep(ledger, event.Step) || event.Reason != "" || len(event.Evidence) == 0 || isCreateStep(event.Step) {
				return Ledger{}, ErrJournal
			}
			ledger.Completed = append(ledger.Completed, Record{Step: event.Step, Evidence: append(json.RawMessage(nil), event.Evidence...)})
		case "unknown":
			if ledger.Unknown || pending == nil || *pending != event.Step || event.Reason == "" || len(event.Evidence) != 0 {
				return Ledger{}, ErrJournal
			}
			ledger.Unknown = true
		default:
			return Ledger{}, ErrJournal
		}
		previous = event.Hash
	}
	ledger.Pending = pending
	return ledger, nil
}

func (j *FSJournal) appendLocked(kind string, step Step, evidence json.RawMessage, reason string) error {
	if err := validJournalFile(j.file); err != nil {
		return err
	}
	info, err := j.file.Stat()
	if err != nil || info.Size() > maxJournal-4096 {
		return ErrJournal
	}
	if _, err := j.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	ledgerRaw, err := io.ReadAll(io.LimitReader(j.file, maxJournal+1))
	if err != nil || len(ledgerRaw) > maxJournal {
		return ErrJournal
	}
	if _, err := replayJournal(ledgerRaw, j.digest, j.binding); err != nil {
		return err
	}
	if _, err := j.file.Seek(0, io.SeekEnd); err != nil {
		return err
	}
	previous := ""
	if len(ledgerRaw) > 0 {
		last := strings.Split(string(ledgerRaw[:len(ledgerRaw)-1]), "\n")
		var tail fsEvent
		if err := contract.DecodeStrict([]byte(last[len(last)-1]), &tail); err != nil {
			return err
		}
		previous = tail.Hash
	}
	event := fsEvent{Schema: fsSchema, BindingDigest: j.digest, Sequence: uint64(strings.Count(string(ledgerRaw), "\n") + 1), Previous: previous, Kind: kind, Step: step, Evidence: append(json.RawMessage(nil), evidence...), Reason: reason}
	payload := fsEventPayload{event.Schema, event.BindingDigest, event.Sequence, event.Previous, event.Kind, event.Step, event.Evidence, event.Reason}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(encoded)
	event.Hash = hex.EncodeToString(sum[:])
	line, err := json.Marshal(event)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	if int64(len(line)) > maxJournal-info.Size() {
		return ErrJournal
	}
	if _, err := j.file.Write(line); err != nil {
		return err
	}
	if err := j.file.Sync(); err != nil {
		return err
	}
	return nil
}

func (j *FSJournal) syncDirectory() error {
	dir, err := j.root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func nextStep(ledger Ledger, step Step) bool {
	return len(ledger.Completed) < len(orderedSteps) && orderedSteps[len(ledger.Completed)] == step
}

func isCreateStep(step Step) bool {
	return step == ControlCreate || step == RecoveryCreate || step == StandardCreate
}

func validEvidence(raw json.RawMessage) bool {
	if len(raw) == 0 || !json.Valid(raw) {
		return false
	}
	var compact bytes.Buffer
	if json.Compact(&compact, raw) != nil {
		return false
	}
	return bytes.Equal(compact.Bytes(), raw)
}

func validCreatePin(raw json.RawMessage, binding contract.RunBinding, digest string) bool {
	var pin isolation.PinnedResource
	if contract.DecodeStrict(raw, &pin) != nil || !contract.IsDigest(pin.ID) || !journalResourceName.MatchString(pin.Name) || pin.RunID != binding.RunID || pin.OwnershipMarker != binding.OwnershipMarker || pin.BindingDigest != digest || !validJournalImage(pin.Image) || (pin.ForkKey != "fork-a" && pin.ForkKey != "fork-b") || pin.Network != nil || len(pin.Ports) != 0 {
		return false
	}
	if pin.SelectedBinaryRole != isolation.BinaryOriginal && pin.SelectedBinaryRole != isolation.BinaryRecovery {
		return false
	}
	if pin.SelectedBinaryPath != binding.Paths[string(pin.SelectedBinaryRole)+"-binary"] || pin.SelectedBinaryDigest != binding.InputDigests[string(pin.SelectedBinaryRole)+"-binary"] {
		return false
	}
	canonical, err := json.Marshal(pin)
	return err == nil && reflect.DeepEqual(raw, json.RawMessage(canonical))
}

func validJournalImage(image string) bool {
	at := strings.LastIndex(image, "@sha256:")
	if at <= 0 || strings.Count(image, "@") != 1 || !journalImageName.MatchString(image[:at]) {
		return false
	}
	return contract.IsDigest(image[at+8:])
}

var journalImageName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._/:+-]*$`)

func openSafeJournalFile(root *os.Root, name string, flags int) (*os.File, error) {
	if info, err := root.Lstat(name); err == nil && !safeJournalInfo(info) {
		return nil, fmt.Errorf("unsafe driver journal file %s: %w", name, ErrJournal)
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	f, err := root.OpenFile(name, flags, 0o600)
	if err != nil {
		return nil, err
	}
	if err := validJournalFile(f); err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

func validJournalFile(f *os.File) error {
	info, err := f.Stat()
	if err != nil || !safeJournalInfo(info) {
		return ErrJournal
	}
	return nil
}

func safeJournalInfo(info os.FileInfo) bool {
	if info == nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Nlink == 1 && stat.Uid == uint32(os.Geteuid())
}

func checkFSJournalRoot(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return ErrJournal
	}
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("unsafe driver journal workspace: %w", ErrJournal)
		}
		if current == filepath.Dir(current) {
			break
		}
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&0o077 != 0 {
		return fmt.Errorf("driver journal requires an existing private workspace: %w", ErrJournal)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return ErrJournal
	}
	return nil
}
