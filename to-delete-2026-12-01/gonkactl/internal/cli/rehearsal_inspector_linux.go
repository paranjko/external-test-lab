//go:build linux

package cli

import (
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

func nativeInspectorReader(o inspectorOptions) (session.SnapshotReader, error) {
	return session.NewInspectorSnapshotReader(session.InspectorConfig{
		BinaryPath: o.BinaryPath, BinarySHA256: o.BinarySHA256,
		Version: o.Version, SourceCommit: o.SourceCommit, TempRoot: o.TempRoot,
		MaxCopyBytes: o.MaxCopyBytes, MaxDumpBytes: o.MaxDumpBytes,
		MaxOutputFSBytes: o.MaxOutputFSBytes, Timeout: time.Duration(o.TimeoutSeconds) * time.Second,
		MaxLogBytes: o.MaxLogBytes, ReserveBytes: o.ReserveBytes,
	})
}
