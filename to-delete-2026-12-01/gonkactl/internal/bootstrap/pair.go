package bootstrap

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type fileState struct {
	Exists bool   `json:"exists"`
	Data   []byte `json:"data"`
	Mode   uint32 `json:"mode"`
}
type pairJournal struct {
	Version int          `json:"version"`
	Chain   string       `json:"chain"`
	Before  [2]fileState `json:"before"`
	After   [2]fileState `json:"after"`
}
type pairStore struct {
	directory, chain string
	lock             *os.File
	before           [2]fileState
	// Fault injection stays private to package tests; the CLI never exposes it.
	afterWrite func(int) error
}

func transactionPath(directory, chain string) string {
	return filepath.Join(directory, ".gonkactl-"+chain+".txn")
}

func pendingTransaction(directory, chain string) error {
	_, err := os.Lstat(transactionPath(directory, chain))
	if err == nil {
		return fmt.Errorf("bootstrap has a pending update; rerun bootstrap update to recover")
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func snapshot(path string) (fileState, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fileState{}, nil
	}
	if err != nil {
		return fileState{}, err
	}
	if !info.Mode().IsRegular() {
		return fileState{}, fmt.Errorf("bootstrap target must be a regular file, not a symlink")
	}
	data, err := readBounded(path)
	if err != nil {
		return fileState{}, err
	}
	return fileState{true, data, uint32(info.Mode().Perm())}, nil
}

func sameState(a, b fileState) bool {
	return a.Exists == b.Exists && bytes.Equal(a.Data, b.Data) && a.Mode == b.Mode
}

func openPairStore(directory, chain string) (*pairStore, error) {
	if !chainName.MatchString(chain) || directory == "" {
		return nil, fmt.Errorf("invalid bootstrap output target")
	}
	if err := os.MkdirAll(directory, 0755); err != nil {
		return nil, err
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("output directory must not be a symlink")
	}
	lockPath := filepath.Join(directory, ".gonkactl-"+chain+".lock")
	if info, err := os.Lstat(lockPath); err == nil && (!info.Mode().IsRegular() || info.Size() != 0) {
		return nil, fmt.Errorf("unsafe bootstrap lock file")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := lockExclusive(lock); err != nil {
		lock.Close()
		return nil, fmt.Errorf("another bootstrap update holds the output lock: %w", err)
	}
	store := &pairStore{directory: directory, chain: chain, lock: lock}
	if err := store.recover(false); err != nil {
		store.Close()
		return nil, err
	}
	for index, path := range store.paths() {
		state, err := snapshot(path)
		if err != nil {
			store.Close()
			return nil, err
		}
		store.before[index] = state
	}
	return store, nil
}

func (s *pairStore) Close() error { return s.lock.Close() }
func (s *pairStore) paths() [2]string {
	return [2]string{filepath.Join(s.directory, s.chain+".json"), filepath.Join(s.directory, s.chain+".env")}
}

func (s *pairStore) atomicWrite(path string, state fileState) error {
	if !state.Exists {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return syncDirectory(s.directory)
	}
	file, err := os.CreateTemp(s.directory, ".gonkactl-"+s.chain+"-*")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err := file.Write(state.Data); err != nil {
		file.Close()
		return err
	}
	if err := file.Chmod(os.FileMode(state.Mode)); err != nil {
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
	if err := os.Rename(name, path); err != nil {
		return err
	}
	return syncDirectory(s.directory)
}

func (s *pairStore) recover(forceRollback bool) error {
	path := transactionPath(s.directory, s.chain)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("unsafe bootstrap transaction file")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	raw, err := io.ReadAll(io.LimitReader(file, 2*1024*1024+1))
	file.Close()
	if err != nil || len(raw) > 2*1024*1024 {
		return fmt.Errorf("invalid bootstrap transaction size")
	}
	var journal pairJournal
	if err := DecodeJSON(raw, &journal); err != nil {
		return fmt.Errorf("invalid bootstrap recovery journal")
	}
	if journal.Version != 1 || journal.Chain != s.chain {
		return fmt.Errorf("bootstrap recovery journal identity mismatch")
	}
	for _, pair := range [][2]fileState{journal.Before, journal.After} {
		for _, state := range pair {
			if len(state.Data) > DocumentLimit || state.Mode > 0777 || (!state.Exists && (len(state.Data) != 0 || state.Mode != 0)) {
				return fmt.Errorf("invalid bootstrap recovery file state")
			}
		}
	}
	if !journal.After[0].Exists || !journal.After[1].Exists {
		return fmt.Errorf("incomplete bootstrap recovery target")
	}
	doc, err := Parse(journal.After[0].Data, nil)
	if err != nil || doc.ChainID != s.chain || !bytes.Equal(doc.ENV(), journal.After[1].Data) {
		return fmt.Errorf("invalid bootstrap recovery target")
	}
	complete := true
	for index, target := range s.paths() {
		state, err := snapshot(target)
		if err != nil {
			return err
		}
		if !sameState(state, journal.Before[index]) && !sameState(state, journal.After[index]) {
			return fmt.Errorf("bootstrap changed outside the pending transaction; preserving files and journal")
		}
		complete = complete && sameState(state, journal.After[index])
	}
	if forceRollback || !complete {
		for index, target := range s.paths() {
			if err := s.atomicWrite(target, journal.Before[index]); err != nil {
				return fmt.Errorf("bootstrap rollback incomplete; journal retained: %w", err)
			}
		}
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	return syncDirectory(s.directory)
}

// Commit journals old and new bytes before either rename. Ordinary errors
// restore the old pair. After a crash, reopening rolls back a partial pair or
// finalizes an already complete pair. Legacy readers must not race this writer:
// two ordinary files cannot be renamed atomically as one filesystem operation.
func (s *pairStore) Commit(raw, env []byte) (bool, error) {
	doc, err := Parse(raw, nil)
	if err != nil || doc.ChainID != s.chain || !bytes.Equal(doc.ENV(), env) {
		return false, fmt.Errorf("refusing an invalid bootstrap pair")
	}
	after := [2]fileState{{Exists: true, Data: raw, Mode: newFileMode()}, {Exists: true, Data: env, Mode: newFileMode()}}
	unchanged := true
	for index, target := range s.paths() {
		current, err := snapshot(target)
		if err != nil {
			return false, err
		}
		if !sameState(current, s.before[index]) {
			return false, fmt.Errorf("bootstrap changed during validation; refusing overwrite")
		}
		if current.Exists {
			after[index].Mode = current.Mode
		}
		unchanged = unchanged && sameState(current, after[index])
	}
	if unchanged {
		return false, nil
	}
	journal := pairJournal{Version: 1, Chain: s.chain, Before: s.before, After: after}
	encoded, err := json.Marshal(journal)
	if err != nil {
		return false, err
	}
	path := transactionPath(s.directory, s.chain)
	file, err := os.CreateTemp(s.directory, ".gonkactl-"+s.chain+"-journal-*")
	if err != nil {
		return false, err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	_, writeErr := file.Write(encoded)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return false, fmt.Errorf("transaction preparation failed; output pair unchanged: %w", err)
	}
	// Publish a complete durable journal without replacing an existing one.
	// The temporary and target are on the same filesystem. A crash before this
	// link can leave a temporary file, but never a truncated recovery journal.
	if err := os.Link(temporary, path); err != nil {
		return false, err
	}
	if err := syncDirectory(s.directory); err != nil {
		return false, err
	}
	for index, target := range s.paths() {
		err = s.atomicWrite(target, after[index])
		if err == nil && s.afterWrite != nil {
			err = s.afterWrite(index)
		}
		if err != nil {
			return false, errors.Join(err, s.recover(true))
		}
	}
	if err := os.Remove(path); err != nil {
		return false, errors.Join(err, s.recover(true))
	}
	if err := syncDirectory(s.directory); err != nil {
		return true, fmt.Errorf("pair written but directory durability could not be confirmed: %w", err)
	}
	s.before = after
	return true, nil
}
