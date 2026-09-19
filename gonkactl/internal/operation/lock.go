package operation

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
	"golang.org/x/sys/unix"
)

type lockManager struct{ instanceRoot, hostRoot string }

func (m lockManager) lock(ctx context.Context, resource string) (contracts.Lock, error) {
	if ctx == nil || resource == "" || strings.ContainsAny(resource, `/\\`) || resource == "." || resource == ".." {
		return nil, ErrUnsafePath
	}
	root := m.instanceRoot
	if strings.HasPrefix(resource, "host:") {
		root, resource = m.hostRoot, strings.TrimPrefix(resource, "host:")
	}
	if root == "" || resource == "" {
		return nil, ErrUnsafePath
	}
	if err := privateDirectory(root); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(root, resource+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	for {
		err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return &fileLock{file: file}, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) && !errors.Is(err, unix.EAGAIN) {
			_ = file.Close()
			return nil, fmt.Errorf("lock resource: %w", err)
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

type fileLock struct{ file *os.File }

func (l *fileLock) Close() error {
	if l.file == nil {
		return nil
	}
	err := unix.Flock(int(l.file.Fd()), unix.LOCK_UN)
	closeErr := l.file.Close()
	l.file = nil
	if err != nil {
		return err
	}
	return closeErr
}
