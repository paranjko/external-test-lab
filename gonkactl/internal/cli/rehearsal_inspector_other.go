//go:build !linux && !windows

package cli

import (
	"errors"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

func nativeInspectorReader(inspectorOptions) (session.SnapshotReader, error) {
	return nil, errors.New("offline inspector process execution requires Linux")
}
