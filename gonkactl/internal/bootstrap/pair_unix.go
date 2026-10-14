//go:build !windows

package bootstrap

import (
	"golang.org/x/sys/unix"
	"os"
)

func lockExclusive(file *os.File) error { return unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB) }
func lockShared(file *os.File) error    { return unix.Flock(int(file.Fd()), unix.LOCK_SH|unix.LOCK_NB) }
func newFileMode() uint32               { return 0644 }
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
