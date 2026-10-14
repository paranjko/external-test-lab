package bootstrap

import (
	"golang.org/x/sys/windows"
	"os"
)

func lockExclusive(file *os.File) error {
	return windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &windows.Overlapped{})
}

func lockShared(file *os.File) error {
	return windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &windows.Overlapped{})
}

// Windows does not expose POSIX directory fsync through os.File. File contents
// are flushed before replacement; journal recovery covers process interruption.
func syncDirectory(string) error { return nil }
func newFileMode() uint32        { return 0666 }
