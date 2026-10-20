//go:build !windows

package cli

import (
	"errors"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/session"
)

// This is explicit local process configuration, not an approval or proof.
// Capture's signed input and proof checks still run before any process starts.
type inspectorOptions struct {
	BinaryPath       string `json:"binary_path"`
	BinarySHA256     string `json:"binary_sha256"`
	Version          string `json:"version"`
	SourceCommit     string `json:"source_commit"`
	TempRoot         string `json:"temp_root"`
	MaxCopyBytes     int64  `json:"max_copy_bytes"`
	MaxDumpBytes     int64  `json:"max_dump_bytes"`
	MaxOutputFSBytes int64  `json:"max_output_fs_bytes"`
	TimeoutSeconds   int64  `json:"timeout_seconds"`
	MaxLogBytes      int64  `json:"max_log_bytes"`
	ReserveBytes     int64  `json:"reserve_bytes"`
}

func selectInspectorReader(path string, binding contract.RunBinding, injected session.SnapshotReader) (session.SnapshotReader, error) {
	pin, pinned := binding.InputDigests["inspector-config"]
	if path == "" {
		if pinned {
			return nil, errors.New("bound inspector configuration must be supplied")
		}
		return injected, nil
	}
	if injected != nil {
		return nil, errors.New("explicit inspector configuration conflicts with injected reader")
	}
	raw, err := readLocalJSON(path)
	if err != nil {
		return nil, err
	}
	if !pinned || !contract.IsDigest(pin) || contract.PayloadDigest(raw) != pin {
		return nil, errors.New("inspector configuration differs from immutable run input")
	}
	var options inspectorOptions
	if err := contract.DecodeStrict(raw, &options); err != nil {
		return nil, err
	}
	if options.BinaryPath != binding.Paths["producer-binary"] || options.BinarySHA256 != binding.InputDigests["producer-binary"] || options.TempRoot != binding.Paths["inspector-temp"] {
		return nil, errors.New("inspector paths or executable differ from immutable run input")
	}
	if options.TimeoutSeconds <= 0 || options.TimeoutSeconds > 3600 {
		return nil, errors.New("inspector timeout must be between 1 and 3600 seconds")
	}
	return nativeInspectorReader(options)
}
