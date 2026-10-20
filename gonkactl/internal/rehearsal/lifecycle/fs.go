package lifecycle

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"golang.org/x/sys/unix"
)

type fileOps interface {
	read(*os.Root, string) ([]byte, error)
	createTemp(*os.Root, string) (*os.File, string, error)
	rename(*os.Root, string, string) error
	remove(*os.Root, string) error
	beforePersist() error
}

type osFileOps struct{}

func (osFileOps) read(r *os.Root, p string) ([]byte, error) {
	f, err := r.OpenFile(p, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || !singleLink(info) || !ownedByCurrentUser(info) || info.Size() > 16*1024*1024 {
		return nil, ErrUnsafePath
	}
	return io.ReadAll(io.LimitReader(f, 16*1024*1024+1))
}
func (osFileOps) createTemp(r *os.Root, prefix string) (*os.File, string, error) {
	for i := 0; i < 8; i++ {
		var b [16]byte
		if _, err := rand.Read(b[:]); err != nil {
			return nil, "", err
		}
		name := prefix + hex.EncodeToString(b[:])
		f, err := r.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_RDWR|unix.O_NOFOLLOW, 0o600)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		if err != nil {
			return nil, "", err
		}
		return f, name, nil
	}
	return nil, "", errors.New("could not allocate journal temporary file")
}
func (osFileOps) rename(r *os.Root, a, b string) error { return r.Rename(a, b) }
func (osFileOps) remove(r *os.Root, p string) error    { return r.Remove(p) }
func (osFileOps) beforePersist() error                 { return nil }

func ensurePrivateRoot(root string) (*os.Root, error) {
	parent := filepath.Dir(root)
	base := filepath.Base(root)
	for current := parent; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err == nil && info.Mode()&os.ModeSymlink != 0 {
			return nil, ErrUnsafePath
		}
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		next := filepath.Dir(current)
		if next == current {
			break
		}
	}
	parentInfo, err := os.Lstat(parent)
	if err != nil || !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 || parentInfo.Mode().Perm()&0o022 != 0 || !ownedByCurrentUser(parentInfo) {
		return nil, ErrUnsafePath
	}
	parentRoot, err := os.OpenRoot(parent)
	if err != nil {
		return nil, err
	}
	keepParent := false
	defer func() {
		if !keepParent {
			parentRoot.Close()
		}
	}()
	check, err := parentRoot.Open(".")
	if err != nil {
		return nil, err
	}
	openedInfo, err := check.Stat()
	check.Close()
	if err != nil || !os.SameFile(parentInfo, openedInfo) {
		return nil, ErrUnsafePath
	}
	if err := parentRoot.Mkdir(base, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return nil, err
	}
	info, err := parentRoot.Lstat(base)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o077 != 0 || !ownedByCurrentUser(info) {
		return nil, ErrUnsafePath
	}
	rootHandle, err := parentRoot.OpenRoot(base)
	if err != nil {
		return nil, err
	}
	child, err := rootHandle.Open(".")
	if err != nil {
		rootHandle.Close()
		return nil, err
	}
	childInfo, err := child.Stat()
	child.Close()
	if err != nil || !os.SameFile(info, childInfo) {
		rootHandle.Close()
		return nil, ErrUnsafePath
	}
	keepParent = true
	parentRoot.Close()
	return rootHandle, nil
}

func atomicWrite(ops fileOps, root *os.Root, path string, value []byte) error {
	tmp, tempName, err := ops.createTemp(root, ".lifecycle-")
	if err != nil {
		return err
	}
	defer ops.remove(root, tempName)
	if _, err := tmp.Write(value); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := ops.rename(root, tempName, path); err != nil {
		return err
	}
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func syncRoot(root *os.Root) error {
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func singleLink(info os.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && st.Nlink == 1
}

func ownedByCurrentUser(info os.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid()
}

func cloneBinding(b contract.RunBinding) (contract.RunBinding, error) {
	raw, err := json.Marshal(b)
	if err != nil {
		return contract.RunBinding{}, err
	}
	var out contract.RunBinding
	err = json.Unmarshal(raw, &out)
	return out, err
}
