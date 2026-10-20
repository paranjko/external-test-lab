package lifecycle

import (
	"os"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"golang.org/x/sys/unix"
)

// ReadStoredSnapshot never creates a directory, lock, journal or reconciliation
// record. Interrupted intents are presented as Unknown without changing bytes.
func ReadStoredSnapshot(root string) (binding contract.RunBinding, state contract.State, revision string, receipts []contract.Receipt, err error) {
	if !filepath.IsAbs(root) || filepath.Clean(root) != root || root == "/" {
		err = ErrUnsafePath
		return
	}
	for p := root; ; p = filepath.Dir(p) {
		var info os.FileInfo
		info, err = os.Lstat(p)
		if err != nil {
			return
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			err = ErrUnsafePath
			return
		}
		if p == filepath.Dir(p) {
			break
		}
	}
	var before os.FileInfo
	before, err = os.Lstat(root)
	if err != nil {
		return
	}
	if before.Mode().Perm() != 0700 {
		err = ErrUnsafePath
		return
	}
	var dir *os.Root
	dir, err = os.OpenRoot(root)
	if err != nil {
		return
	}
	defer dir.Close()
	var pinned os.FileInfo
	pinned, err = dir.Stat(".")
	if err != nil {
		return
	}
	if !os.SameFile(before, pinned) {
		err = ErrUnsafePath
		return
	}
	var lock *os.File
	lock, err = dir.OpenFile(".lifecycle.lock", os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return
	}
	defer lock.Close()
	var info os.FileInfo
	info, err = lock.Stat()
	if err != nil {
		return
	}
	if !info.Mode().IsRegular() || !singleLink(info) || info.Mode().Perm()&0077 != 0 {
		err = ErrUnsafePath
		return
	}
	err = unix.Flock(int(lock.Fd()), unix.LOCK_SH|unix.LOCK_NB)
	if err != nil {
		return
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	var raw []byte
	raw, err = (osFileOps{}).read(dir, journalName)
	if err != nil {
		return
	}
	var d document
	err = contract.DecodeStrict(raw, &d)
	if err != nil {
		return
	}
	err = contract.ValidateBinding(d.Binding)
	if err != nil {
		return
	}
	if d.Version != contract.Version || d.Binding.Workspace != root || d.BindingDigest != mustDigest(d.Binding) {
		err = ErrConflict
		return
	}
	revision = d.Revision
	d.Revision = ""
	var actual string
	actual, err = digestDocument(d)
	if err != nil {
		return
	}
	if revision == "" || revision != actual {
		err = ErrConflict
		return
	}
	d.Revision = revision
	err = validateJournal(d)
	if err != nil {
		return
	}
	binding, state = d.Binding, d.State
	if d.Pending != nil || d.Quarantined || d.InitClaimed && d.State == contract.Running && !operationRecorded(d.Entries, "init") {
		state = contract.Unknown
	}
	for _, item := range d.Entries {
		receipts = append(receipts, item.Receipt)
	}
	return
}
