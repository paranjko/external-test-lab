package operation

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

var ErrConflict = errors.New("operation store conflict")
var ErrUnsafePath = errors.New("unsafe operation store path")

type Store struct {
	root      string
	validator contracts.Validator
	allowed   map[string]struct{}
	locks     lockManager
}

// NewStore limits all document keys to the command-owned allowlist. A nil
// validator is rejected at write time: unvalidated state never enters storage.
func NewStore(root string, validator contracts.Validator, allowedKeys []string, hostLockRoot string) (*Store, error) {
	if !filepath.IsAbs(root) || root == "/" {
		return nil, fmt.Errorf("%w: root must be a private absolute directory", ErrUnsafePath)
	}
	if err := privateDirectory(root); err != nil {
		return nil, err
	}
	allowed := make(map[string]struct{}, len(allowedKeys))
	for _, key := range allowedKeys {
		if !safeKey(key) {
			return nil, fmt.Errorf("%w: invalid allowlist key", ErrUnsafePath)
		}
		allowed[key] = struct{}{}
	}
	return &Store{root: root, validator: validator, allowed: allowed, locks: lockManager{instanceRoot: filepath.Join(root, ".locks"), hostRoot: hostLockRoot}}, nil
}

func (s *Store) Read(ctx context.Context, key string) (contracts.Document, error) {
	if err := ctx.Err(); err != nil {
		return contracts.Document{}, err
	}
	path, err := s.path(key)
	if err != nil {
		return contracts.Document{}, err
	}
	bytes, err := readNoSymlink(path)
	if err != nil {
		return contracts.Document{}, err
	}
	return contracts.Document{SchemaRef: "", Bytes: bytes, SHA256: digest(bytes)}, nil
}

func (s *Store) CAS(ctx context.Context, key string, expectedSHA256 *string, next contracts.Document) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, err := s.path(key)
	if err != nil {
		return err
	}
	if next.SchemaRef == "" || s.validator == nil {
		return errors.New("schema validation is required before store write")
	}
	if err := s.validator.Validate(next.SchemaRef, next.Bytes); err != nil {
		return fmt.Errorf("document validation: %w", err)
	}
	if next.SHA256 != "" && next.SHA256 != digest(next.Bytes) {
		return errors.New("document digest does not match bytes")
	}
	current, err := readNoSymlink(path)
	if err == nil {
		if expectedSHA256 == nil || *expectedSHA256 != digest(current) {
			return ErrConflict
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	} else if expectedSHA256 != nil {
		return ErrConflict
	}
	return atomicWrite(path, next.Bytes)
}

func (s *Store) Lock(ctx context.Context, resource string) (contracts.Lock, error) {
	return s.locks.lock(ctx, resource)
}

func (s *Store) path(key string) (string, error) {
	if _, ok := s.allowed[key]; !ok || !safeKey(key) {
		return "", fmt.Errorf("%w: key is not command-owned", ErrUnsafePath)
	}
	path := filepath.Join(s.root, filepath.FromSlash(key))
	if !within(s.root, path) {
		return "", ErrUnsafePath
	}
	return path, nil
}

func safeKey(key string) bool {
	if key == "" || filepath.IsAbs(key) || strings.Contains(key, "\\") {
		return false
	}
	for _, part := range strings.Split(key, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return filepath.Clean(key) == key
}

func privateDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	}
	return os.Chmod(path, 0o700)
}

func readNoSymlink(path string) ([]byte, error) {
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err == nil && info.Mode()&os.ModeSymlink != 0 {
			return nil, ErrUnsafePath
		}
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
	}
	return os.ReadFile(path)
}

func atomicWrite(path string, value []byte) error {
	if err := privateDirectory(filepath.Dir(path)); err != nil {
		return err
	}
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".gonkactl-store-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(value); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func digest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func within(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

var _ contracts.Store = (*Store)(nil)
