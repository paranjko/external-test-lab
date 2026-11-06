//go:build linux

package session

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
)

const inspectorMarker = ".gnklab-readonly-copy.json"
const inspectorTmpfsMagic = 0x01021994
const maxInspectorOutputFSBytes = int64(256 << 20)
const maxInspectorLogBytes = int64(1 << 20)
const maxInspectorCopyEntries = 100_000
const maxInspectorCopyDepth = 32
const inspectorCopyReadBatch = 256

// InspectorConfig pins the local producer and bounds all local work. TempRoot
// must be a tmpfs whose entire size is no greater than MaxOutputFSBytes; this
// makes the inspector's output files hard-bounded even though the producer's
// logical-byte limit does not bound JSON encoding overhead.
type InspectorConfig struct {
	BinaryPath       string
	BinarySHA256     string
	Version          string
	SourceCommit     string
	TempRoot         string
	MaxCopyBytes     int64
	MaxDumpBytes     int64
	MaxOutputFSBytes int64
	ReserveBytes     int64
	Timeout          time.Duration
	MaxLogBytes      int64

	// helperProcess is only for package tests and is not configurable by callers.
	helperProcess     bool
	helperFailure     bool
	helperLogOverflow bool
	filesystem        inspectorFilesystem
}

type inspectorFilesystem interface {
	checkOutputRoot(string, int64, int64) error
	checkWorkspace(string, int64) error
}

type InspectorSnapshotReader struct{ config InspectorConfig }

func NewInspectorSnapshotReader(config InspectorConfig) (*InspectorSnapshotReader, error) {
	if config.BinaryPath == "" || !filepath.IsAbs(config.BinaryPath) || filepath.Clean(config.BinaryPath) != config.BinaryPath || !contract.IsDigest(config.BinarySHA256) {
		return nil, errors.New("inspector requires an absolute pinned producer binary")
	}
	if strings.TrimSpace(config.Version) == "" || !validSourceCommit(config.SourceCommit) {
		return nil, errors.New("inspector producer version and source commit are required")
	}
	if config.TempRoot == "" || !filepath.IsAbs(config.TempRoot) || filepath.Clean(config.TempRoot) != config.TempRoot {
		return nil, errors.New("inspector output root must be a clean absolute path")
	}
	if config.MaxCopyBytes <= 0 || config.MaxDumpBytes <= 0 || config.MaxOutputFSBytes <= 0 || config.ReserveBytes <= 0 || config.Timeout <= 0 || config.MaxLogBytes <= 0 || config.MaxLogBytes > maxInspectorLogBytes {
		return nil, errors.New("inspector copy, dump, output, timeout, and log limits must be positive")
	}
	maxInt64 := int64(^uint64(0) >> 1)
	if config.ReserveBytes > maxInt64-config.MaxCopyBytes || config.ReserveBytes > maxInt64-config.MaxDumpBytes || config.ReserveBytes > maxInt64-config.MaxOutputFSBytes {
		return nil, errors.New("inspector capacity and reserve limits overflow")
	}
	if config.MaxCopyBytes > maxInt64-(config.MaxOutputFSBytes+config.ReserveBytes) {
		return nil, errors.New("inspector retained evidence capacity limits overflow")
	}
	if config.MaxOutputFSBytes > maxInspectorOutputFSBytes || config.MaxDumpBytes+config.ReserveBytes > config.MaxOutputFSBytes {
		return nil, errors.New("inspector logical dump limit exceeds the hard output filesystem limit")
	}
	return &InspectorSnapshotReader{config: config}, nil
}

var _ SnapshotReader = (*InspectorSnapshotReader)(nil)

type inspectorExecution struct {
	SchemaVersion string `json:"schema_version"`
	RunID         string `json:"run_id"`
	BindingSHA256 string `json:"binding_sha256"`
	Status        string `json:"status"`
	Qualification string `json:"qualification"`
	Producer      struct {
		SHA256       string `json:"sha256"`
		Version      string `json:"version"`
		SourceCommit string `json:"source_commit"`
	} `json:"producer"`
	StartedUTC           string                `json:"started_utc"`
	FinishedUTC          string                `json:"finished_utc"`
	Arguments            []string              `json:"arguments"`
	ArgumentsSHA256      string                `json:"arguments_sha256"`
	ExitCode             int                   `json:"exit_code"`
	StdoutObservedBytes  int64                 `json:"stdout_observed_bytes"`
	StdoutRetainedBytes  int64                 `json:"stdout_retained_bytes"`
	StdoutRetainedSHA256 string                `json:"stdout_retained_sha256"`
	StdoutTruncated      bool                  `json:"stdout_truncated"`
	StderrObservedBytes  int64                 `json:"stderr_observed_bytes"`
	StderrRetainedBytes  int64                 `json:"stderr_retained_bytes"`
	StderrRetainedSHA256 string                `json:"stderr_retained_sha256"`
	StderrTruncated      bool                  `json:"stderr_truncated"`
	Stdout               string                `json:"stdout,omitempty"`
	Stderr               string                `json:"stderr,omitempty"`
	Summary              coregate.SourceDigest `json:"summary"`
	ApplicationDump      coregate.SourceDigest `json:"application_dump"`
	PartialSummary       coregate.SourceDigest `json:"partial_summary,omitempty"`
	PartialDump          coregate.SourceDigest `json:"partial_dump,omitempty"`
	PartialDumpTemp      coregate.SourceDigest `json:"partial_dump_temporary,omitempty"`
	SnapshotSHA256       string                `json:"snapshot_sha256,omitempty"`
	RetainedSummary      string                `json:"retained_summary,omitempty"`
	RetainedDump         string                `json:"retained_application_dump,omitempty"`
	RetainedDumpTemp     string                `json:"retained_partial_dump,omitempty"`
	PreservedCopy        string                `json:"preserved_copy,omitempty"`
	PreservedOutput      string                `json:"preserved_output,omitempty"`
	Error                string                `json:"error,omitempty"`
}

func (r *InspectorSnapshotReader) ReadSnapshot(ctx context.Context, binding contract.RunBinding) (contract.Snapshot, error) {
	var empty contract.Snapshot
	return empty, errors.New("inspector requires a caller-authenticated source manifest")
}

// ReadManifestSnapshot consumes a source manifest already authenticated by the
// capture adapter. It verifies the exact disposable copy before adding the
// inspector marker or invoking the pinned producer.
func (r *InspectorSnapshotReader) ReadManifestSnapshot(ctx context.Context, binding contract.RunBinding, manifest contract.SourceManifest) (contract.Snapshot, error) {
	var empty contract.Snapshot
	if ctx == nil {
		return empty, errors.New("inspector context is required")
	}
	workCtx, cancelWork := context.WithTimeout(ctx, r.config.Timeout)
	defer cancelWork()
	ctx = workCtx
	if err := contract.ValidateBinding(binding); err != nil {
		return empty, fmt.Errorf("validate inspector run binding: %w", err)
	}
	if err := validateAuthenticatedInspectorManifest(binding, manifest, r.config.MaxCopyBytes); err != nil {
		return empty, err
	}
	if binding.Paths["producer-binary"] != r.config.BinaryPath || binding.InputDigests["producer-binary"] != r.config.BinarySHA256 {
		return empty, errors.New("inspector producer path and digest must exactly match the run binding")
	}
	if binding.Paths["inspector-temp"] != r.config.TempRoot {
		return empty, errors.New("inspector temp root must exactly match the run-bound inspector-temp path")
	}
	source := binding.Paths["source"]
	if source == "" || !withinWorkspace(binding.Workspace, source) {
		return empty, errors.New("inspector source must be the bound copied source inside the run workspace")
	}
	if pathsOverlap(source, r.config.TempRoot) || pathsOverlap(source, r.config.BinaryPath) {
		return empty, errors.New("inspector producer and tmpfs mount root must not overlap the bound source")
	}
	copyRoot, sourceInfo, err := openCopiedSourceRoot(source)
	if err != nil {
		return empty, err
	}
	defer copyRoot.Close()
	if err := r.checkOutputFS(); err != nil {
		return empty, err
	}
	if err := r.checkWorkspaceCapacity(binding.Workspace); err != nil {
		return empty, err
	}
	if err := r.verifyProducer(); err != nil {
		return empty, err
	}
	workspaceInfo, err := os.Lstat(binding.Workspace)
	if err != nil || !workspaceInfo.IsDir() || workspaceInfo.Mode()&os.ModeSymlink != 0 || workspaceInfo.Mode().Perm() != 0700 || !ownedByCurrentUser(workspaceInfo) {
		return empty, errors.New("inspector workspace must be a privately owned real directory")
	}
	wsRoot, err := os.OpenRoot(binding.Workspace)
	if err != nil {
		return empty, err
	}
	defer wsRoot.Close()
	if err := preflightInspectorEvidence(wsRoot, binding.RunID); err != nil {
		return empty, err
	}
	workName, err := os.MkdirTemp(binding.Workspace, ".inspector-copy-")
	if err != nil {
		return empty, fmt.Errorf("create disposable inspector copy: %w", err)
	}
	preserveArtifacts := false
	defer func() {
		if !preserveArtifacts {
			_ = os.RemoveAll(workName)
		}
	}()
	if err := os.Chmod(workName, 0700); err != nil {
		return empty, err
	}
	copyBytes, copyEntries, err := r.cloneSource(ctx, copyRoot, source, workName, sourceInfo)
	if err != nil {
		return empty, fmt.Errorf("clone bound source for inspector: %w", err)
	}
	if copyBytes > r.config.MaxCopyBytes {
		return empty, errors.New("inspector source copy exceeds configured byte limit")
	}
	if copyEntries > maxInspectorCopyEntries {
		return empty, errors.New("inspector source exceeds configured entry-count limit")
	}
	if err := requireInspectorLayout(filepath.Join(workName, "node")); err != nil {
		return empty, err
	}
	cloneNode := filepath.Join(workName, "node")
	cloneRoot, cloneInfo, err := openCopiedSourceRoot(cloneNode)
	if err != nil {
		return empty, fmt.Errorf("open disposable inspector copy: %w", err)
	}
	if _, err := verifyCopiedInventory(cloneRoot, cloneNode, cloneInfo, manifest.Files, nil); err != nil {
		cloneRoot.Close()
		return empty, fmt.Errorf("disposable inspector copy differs from authenticated source manifest: %w", err)
	}
	if err := cloneRoot.Close(); err != nil {
		return empty, err
	}
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	markerPath := filepath.Join(workName, "node", inspectorMarker)
	if _, err := os.Lstat(markerPath); err == nil || !errors.Is(err, os.ErrNotExist) {
		return empty, errors.New("bound source contains reserved inspector copy marker")
	}
	marker, _ := json.Marshal(struct {
		Kind       string `json:"kind"`
		SourceRoot string `json:"source_root"`
		CreatedUTC string `json:"created_utc"`
	}{"gnklab-readonly-db-copy-v1", source, time.Now().UTC().Format(time.RFC3339Nano)})
	marker = append(marker, '\n')
	if int64(len(marker)) > r.config.MaxCopyBytes-copyBytes {
		return empty, errors.New("inspector copy marker exceeds configured source copy byte limit")
	}
	if err := os.WriteFile(markerPath, marker, 0600); err != nil {
		return empty, err
	}
	if err := syncDir(filepath.Join(workName, "node")); err != nil {
		return empty, err
	}
	outParent, err := os.MkdirTemp(r.config.TempRoot, "gnklab-inspector-")
	if err != nil {
		return empty, fmt.Errorf("create bounded inspector output workspace: %w", err)
	}
	defer func() {
		if !preserveArtifacts {
			_ = os.RemoveAll(outParent)
		}
	}()
	if err := os.Chmod(outParent, 0700); err != nil {
		return empty, err
	}
	outDir := filepath.Join(outParent, "output")
	allowedRoot := workName
	nodeRoot := filepath.Join(workName, "node")
	args := []string{"--allowed-root", allowedRoot, "--node-root", nodeRoot, "--out", outDir, "--backend", "goleveldb", "--max-dump-bytes", fmt.Sprint(r.config.MaxDumpBytes)}
	argsDigest, _ := contract.Digest(args)

	binary, err := openPinnedExecutable(r.config.BinaryPath, r.config.BinarySHA256)
	if err != nil {
		return empty, err
	}
	defer binary.Close()
	started := time.Now().UTC()
	cmdCtx, cancelCmd := context.WithCancel(ctx)
	defer cancelCmd()
	cmd := exec.CommandContext(cmdCtx, "/proc/self/fd/3", args...)
	cmd.ExtraFiles = []*os.File{binary}
	cmd.Dir = string(filepath.Separator)
	cmd.Env = []string{"LANG=C", "LC_ALL=C", "TZ=UTC"}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 2 * time.Second
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		if err := unix.Kill(-cmd.Process.Pid, unix.SIGKILL); err != nil && !errors.Is(err, unix.ESRCH) {
			return err
		}
		return nil
	}
	if r.config.helperProcess {
		cmd.Args = append([]string{cmd.Path, "-test.run=^TestInspectorHelperProcess$", "--"}, args...)
		cmd.Env = append(cmd.Env, "GNKLAB_INSPECTOR_HELPER=1")
		if r.config.helperFailure {
			cmd.Env = append(cmd.Env, "GNKLAB_INSPECTOR_HELPER_FAILURE=1")
		}
		if r.config.helperLogOverflow {
			cmd.Env = append(cmd.Env, "GNKLAB_INSPECTOR_HELPER_LOG_OVERFLOW=1")
		}
	}
	stdout := &limitedCapture{limit: r.config.MaxLogBytes, cancel: cancelCmd}
	stderr := &limitedCapture{limit: r.config.MaxLogBytes, cancel: cancelCmd}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	runErr := cmd.Run()
	finished := time.Now().UTC()
	if outputErr := validateInspectorOutputInventory(outDir, runErr == nil, r.config.MaxOutputFSBytes); outputErr != nil {
		runErr = errors.Join(runErr, outputErr)
	}
	result := inspectorExecution{SchemaVersion: contract.Version, RunID: binding.RunID, StartedUTC: started.Format(time.RFC3339Nano), FinishedUTC: finished.Format(time.RFC3339Nano), Arguments: append([]string(nil), args...), ArgumentsSHA256: argsDigest, Qualification: "local-only; not runtime-qualified", Status: "failed"}
	result.BindingSHA256, _ = contract.Digest(binding)
	result.Producer.SHA256, result.Producer.Version, result.Producer.SourceCommit = r.config.BinarySHA256, r.config.Version, r.config.SourceCommit
	result.ExitCode = -1
	if cmd.ProcessState != nil {
		result.ExitCode = cmd.ProcessState.ExitCode()
	}
	result.StdoutObservedBytes, result.StdoutRetainedBytes, result.StdoutRetainedSHA256, result.StdoutTruncated = stdout.observedBytes(), stdout.retainedBytes(), stdout.digest(), stdout.truncated()
	result.StderrObservedBytes, result.StderrRetainedBytes, result.StderrRetainedSHA256, result.StderrTruncated = stderr.observedBytes(), stderr.retainedBytes(), stderr.digest(), stderr.truncated()
	result.Stdout, result.Stderr = string(stdout.contents()), string(stderr.contents())
	result.PartialSummary = digestOutputFile(filepath.Join(outDir, "summary.json"), 4<<20)
	result.PartialDump = digestOutputFile(filepath.Join(outDir, "app-kv.jsonl"), r.config.MaxOutputFSBytes)
	result.PartialDumpTemp = digestOutputFile(filepath.Join(outDir, "app-kv.jsonl.tmp"), r.config.MaxOutputFSBytes)
	evidenceDir := filepath.Join(binding.Workspace, "evidence", "inspector", binding.RunID)
	if err := persistInspectorOutputs(wsRoot, binding.RunID, outDir, r.config.MaxOutputFSBytes, &result); err != nil {
		preserveArtifacts = true
		result.Error = err.Error()
		result.PreservedCopy = workName
		result.PreservedOutput = outParent
		receiptErr := persistInspectorExecution(wsRoot, binding.RunID, result)
		return empty, errors.Join(fmt.Errorf("persist raw inspector outputs: %w", err), receiptErr)
	}
	var snapshot contract.Snapshot
	if runErr == nil {
		reader, readErr := coregate.NewFileEvidenceReader(coregate.LocalProvenance{RunID: binding.RunID, BindingDigest: result.BindingSHA256, Nodes: map[string]string{"local": evidenceDir}}, coregate.Limits{InspectorJSON: 4 << 20, AppKVDump: r.config.MaxOutputFSBytes})
		if readErr == nil {
			snapshot, _, _, result.Summary, result.ApplicationDump, readErr = reader.ReadApplicationSnapshot("local")
		}
		var serialized []byte
		if readErr == nil {
			serialized, readErr = json.Marshal(snapshot)
			if readErr == nil && len(serialized)+1 > maxFileSize {
				readErr = errors.New("logical snapshot evidence exceeds session file size limit")
			}
		}
		if readErr != nil {
			runErr = fmt.Errorf("parse bounded inspector output: %w", readErr)
		} else {
			sum := sha256.Sum256(serialized)
			result.SnapshotSHA256 = hex.EncodeToString(sum[:])
			result.Status = "completed-local-inspection"
		}
	}
	if runErr != nil {
		result.Error = runErr.Error()
		result.PreservedCopy = workName
		result.PreservedOutput = outParent
		preserveArtifacts = true
	}
	if err := persistInspectorExecution(wsRoot, binding.RunID, result); err != nil {
		preserveArtifacts = true
		return empty, errors.Join(runErr, fmt.Errorf("persist inspector execution receipt: %w", err))
	}
	if runErr != nil {
		return empty, fmt.Errorf("run offline state inspector: %w", runErr)
	}
	return snapshot, nil
}

func validSourceCommit(value string) bool {
	if len(value) != 40 && len(value) != 64 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && hex.EncodeToString(decoded) == value
}

func validateAuthenticatedInspectorManifest(binding contract.RunBinding, manifest contract.SourceManifest, maxCopyBytes int64) error {
	if err := input.ValidateSourceManifest(manifest); err != nil {
		return fmt.Errorf("caller-authenticated inspector source manifest is invalid: %w", err)
	}
	if _, ok := binding.InputDigests["source_manifest"]; !ok || manifest.RunID != binding.RunID || manifest.ChainID != binding.ChainID || manifest.GenesisSHA256 != binding.GenesisSHA256 {
		return errors.New("authenticated source manifest identity differs from run binding")
	}
	bindingDigest, err := contract.InputBindingDigest(binding)
	if err != nil || manifest.BindingDigest != bindingDigest {
		return errors.New("authenticated source manifest binding digest differs from run binding")
	}
	if !sameInspectorHeights(manifest.Heights, binding.Heights) {
		return errors.New("authenticated source manifest heights differ from run binding")
	}
	if len(manifest.Files) > maxInspectorCopyEntries {
		return errors.New("authenticated source manifest exceeds inspector file-count limit")
	}
	var total int64
	for _, file := range manifest.Files {
		if file.Path == inspectorMarker {
			return errors.New("authenticated source manifest uses the reserved inspector marker path")
		}
		if file.Size > int64(^uint64(0)>>1)-total {
			return errors.New("authenticated source manifest size overflows inspector limit")
		}
		total += file.Size
	}
	markerBudget := int64(len(inspectorMarker) + 128)
	if total > maxCopyBytes || total > int64(^uint64(0)>>1)-markerBudget || total+markerBudget > maxCopyBytes {
		return errors.New("authenticated source manifest exceeds inspector copy byte limit")
	}
	return nil
}

func sameInspectorHeights(a, b contract.Heights) bool {
	if a.Blockstore != b.Blockstore || a.App != b.App || a.FirstRepaired != b.FirstRepaired || a.Consensus == nil || b.Consensus == nil {
		return false
	}
	return *a.Consensus == *b.Consensus
}

func pathsOverlap(a, b string) bool {
	a, errA := filepath.Abs(a)
	b, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return true
	}
	relAB, errAB := filepath.Rel(a, b)
	relBA, errBA := filepath.Rel(b, a)
	return errAB != nil || errBA != nil || relAB == "." || relAB != ".." && !strings.HasPrefix(relAB, ".."+string(filepath.Separator)) || relBA == "." || relBA != ".." && !strings.HasPrefix(relBA, ".."+string(filepath.Separator))
}

func (r *InspectorSnapshotReader) verifyProducer() error {
	f, err := openPinnedExecutable(r.config.BinaryPath, r.config.BinarySHA256)
	if err != nil {
		return err
	}
	return f.Close()
}

func openPinnedExecutable(name, expected string) (*os.File, error) {
	fd, err := unix.Open(name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open pinned inspector producer: %w", err)
	}
	f := os.NewFile(uintptr(fd), name)
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		f.Close()
		return nil, errors.New("inspector producer must be a regular executable")
	}
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		f.Close()
		return nil, err
	}
	if hex.EncodeToString(h.Sum(nil)) != expected {
		f.Close()
		return nil, errors.New("inspector producer digest differs from pinned binary")
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func (r *InspectorSnapshotReader) checkOutputFS() error {
	if r.config.filesystem != nil {
		return r.config.filesystem.checkOutputRoot(r.config.TempRoot, r.config.MaxOutputFSBytes, r.config.MaxDumpBytes+r.config.ReserveBytes)
	}
	info, err := os.Lstat(r.config.TempRoot)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 || !ownedByCurrentUser(info) {
		return errors.New("run-bound inspector tmpfs mount root must be a privately owned real directory")
	}
	var stat unix.Statfs_t
	if err := unix.Statfs(r.config.TempRoot, &stat); err != nil {
		return err
	}
	if stat.Bsize <= 0 || stat.Blocks > uint64(^uint64(0)>>1)/uint64(stat.Bsize) {
		return errors.New("tmpfs capacity value overflows")
	}
	total := int64(stat.Blocks) * int64(stat.Bsize)
	var rootStat, parentStat unix.Stat_t
	if err := unix.Stat(r.config.TempRoot, &rootStat); err != nil {
		return err
	}
	if err := unix.Stat(filepath.Dir(r.config.TempRoot), &parentStat); err != nil {
		return err
	}
	if uint64(stat.Type) != inspectorTmpfsMagic || rootStat.Dev == parentStat.Dev || total <= 0 || total > r.config.MaxOutputFSBytes {
		return errors.New("run-bound inspector output root must be a dedicated tmpfs mount no larger than the configured hard output cap")
	}
	available, err := availableBytes(&stat)
	if err != nil {
		return err
	}
	if available < r.config.MaxDumpBytes+r.config.ReserveBytes {
		return errors.New("insufficient available tmpfs capacity for configured inspector dump limit")
	}
	return nil
}

func (r *InspectorSnapshotReader) checkWorkspaceCapacity(workspace string) error {
	if r.config.filesystem != nil {
		return r.config.filesystem.checkWorkspace(workspace, r.config.MaxCopyBytes+r.config.MaxOutputFSBytes+r.config.ReserveBytes)
	}
	var stat unix.Statfs_t
	if err := unix.Statfs(workspace, &stat); err != nil {
		return err
	}
	available, err := availableBytes(&stat)
	if err != nil {
		return err
	}
	if available < r.config.MaxCopyBytes+r.config.MaxOutputFSBytes+r.config.ReserveBytes {
		return errors.New("insufficient workspace capacity for inspector copy and retained raw output")
	}
	return nil
}

func availableBytes(stat *unix.Statfs_t) (int64, error) {
	if stat.Bsize <= 0 || stat.Bavail > uint64(^uint64(0)>>1)/uint64(stat.Bsize) {
		return 0, errors.New("filesystem capacity value overflows")
	}
	return int64(stat.Bavail) * int64(stat.Bsize), nil
}

func (r *InspectorSnapshotReader) cloneSource(ctx context.Context, sourceRoot *os.Root, sourcePath, workName string, sourceInfo os.FileInfo) (int64, int, error) {
	if sourceInfo.Sys() == nil {
		return 0, 0, errors.New("source identity unavailable")
	}
	openedInfo, err := sourceRoot.Stat(".")
	if err != nil || !os.SameFile(sourceInfo, openedInfo) {
		return 0, 0, errors.New("bound source root identity changed before inspector copy")
	}
	if err := os.Mkdir(filepath.Join(workName, "node"), 0700); err != nil {
		return 0, 0, err
	}
	destRoot, err := os.OpenRoot(filepath.Join(workName, "node"))
	if err != nil {
		return 0, 0, err
	}
	defer destRoot.Close()
	var copied int64
	entries := 0
	if err := copyInspectorDir(ctx, sourceRoot, destRoot, ".", 0, &copied, &entries, r.config.MaxCopyBytes); err != nil {
		return copied, entries, err
	}
	return copied, entries, nil
}

func copyInspectorDir(ctx context.Context, src, dst *os.Root, rel string, depth int, copied *int64, entriesSeen *int, maxBytes int64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if depth > maxInspectorCopyDepth {
		return errors.New("inspector source exceeds maximum directory depth")
	}
	var dir *os.File
	var err error
	if rel == "." {
		dir, err = src.Open(".")
	} else {
		dir, err = src.Open(rel)
	}
	if err != nil {
		return err
	}
	openedDirInfo, err := dir.Stat()
	if err != nil {
		dir.Close()
		return err
	}
	var expectedDirInfo os.FileInfo
	if rel == "." {
		expectedDirInfo, err = src.Stat(".")
	} else {
		expectedDirInfo, err = src.Lstat(rel)
	}
	if err != nil || !os.SameFile(expectedDirInfo, openedDirInfo) {
		dir.Close()
		return errors.New("inspector source directory identity changed during copy")
	}
	defer dir.Close()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		batch, readErr := dir.ReadDir(inspectorCopyReadBatch)
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return readErr
		}
		sort.Slice(batch, func(i, j int) bool { return batch[i].Name() < batch[j].Name() })
		for _, entry := range batch {
			if err := ctx.Err(); err != nil {
				return err
			}
			*entriesSeen++
			if *entriesSeen > maxInspectorCopyEntries {
				return errors.New("inspector source exceeds maximum entry count")
			}
			name := entry.Name()
			if name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
				return errors.New("unsafe source entry name")
			}
			child := name
			if rel != "." {
				child = filepath.Join(rel, name)
			}
			info, err := src.Lstat(child)
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("refuse symlink in copied inspector source: %s", child)
			}
			if info.IsDir() {
				if err := dst.Mkdir(name, 0700); err != nil {
					return err
				}
				dstChild, err := dst.OpenRoot(name)
				if err != nil {
					return err
				}
				err = copyInspectorDir(ctx, src, dstChild, child, depth+1, copied, entriesSeen, maxBytes)
				closeErr := dstChild.Close()
				if err != nil {
					return err
				}
				if closeErr != nil {
					return closeErr
				}
				continue
			}
			if !info.Mode().IsRegular() {
				return fmt.Errorf("refuse special inspector source entry: %s", child)
			}
			st, ok := info.Sys().(*syscall.Stat_t)
			if !ok {
				return fmt.Errorf("inspector source file identity unavailable: %s (%T)", child, info.Sys())
			}
			if st.Nlink != 1 {
				return fmt.Errorf("refuse hard-linked inspector source file: %s", child)
			}
			if info.Size() < 0 || info.Size() > maxBytes-*copied {
				return errors.New("inspector source exceeds configured copy byte limit")
			}
			in, err := src.Open(child)
			if err != nil {
				return err
			}
			openedFileInfo, err := in.Stat()
			if err != nil || !os.SameFile(info, openedFileInfo) {
				in.Close()
				return fmt.Errorf("inspector source file identity changed during copy: %s", child)
			}
			out, err := dst.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err != nil {
				in.Close()
				return err
			}
			n, copyErr := io.CopyN(out, contextReader{ctx: ctx, reader: in}, info.Size()+1)
			if n == info.Size() && copyErr == io.EOF {
				copyErr = nil
			}
			if copyErr == nil && n != info.Size() {
				copyErr = errors.New("source file changed size during inspector copy")
			}
			if copyErr == nil {
				copyErr = out.Sync()
			}
			outErr, inErr := out.Close(), in.Close()
			if copyErr != nil {
				return copyErr
			}
			if outErr != nil {
				return outErr
			}
			if inErr != nil {
				return inErr
			}
			*copied += n
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
	}
	return nil
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(buffer []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(buffer)
}

func requireInspectorLayout(node string) error {
	for _, db := range []string{"application.db", "state.db", "blockstore.db"} {
		info, err := os.Lstat(filepath.Join(node, "data", db))
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("inspector copy lacks required real data/%s directory", db)
		}
	}
	return nil
}

type limitedCapture struct {
	mu     sync.Mutex
	limit  int64
	data   []byte
	size   int64
	tooBig bool
	cancel context.CancelFunc
}

func (w *limitedCapture) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.size += int64(len(p))
	remaining := w.limit - int64(len(w.data))
	if remaining > 0 {
		n := int64(len(p))
		if n > remaining {
			n = remaining
		}
		w.data = append(w.data, p[:n]...)
	}
	if w.size > w.limit {
		w.tooBig = true
		w.cancel()
		return 0, errors.New("inspector log output exceeded configured byte limit")
	}
	return len(p), nil
}

func (w *limitedCapture) digest() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	sum := sha256.Sum256(w.data)
	return hex.EncodeToString(sum[:])
}

func (w *limitedCapture) contents() []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]byte(nil), w.data...)
}

func (w *limitedCapture) observedBytes() int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.size
}

func (w *limitedCapture) retainedBytes() int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return int64(len(w.data))
}

func (w *limitedCapture) truncated() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.size > int64(len(w.data))
}

func digestOutputFile(path string, limit int64) coregate.SourceDigest {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return coregate.SourceDigest{Path: filepath.Base(path)}
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > limit {
		return coregate.SourceDigest{Path: filepath.Base(path)}
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Nlink != 1 {
		return coregate.SourceDigest{Path: filepath.Base(path)}
	}
	h := sha256.New()
	n, err := io.CopyN(h, f, info.Size()+1)
	if n == info.Size() && err == io.EOF {
		err = nil
	}
	if err != nil || n != info.Size() {
		return coregate.SourceDigest{Path: filepath.Base(path)}
	}
	return coregate.SourceDigest{Path: filepath.Base(path), Size: n, SHA256: hex.EncodeToString(h.Sum(nil))}
}

func validateInspectorOutputInventory(outputDir string, success bool, limit int64) error {
	info, err := os.Lstat(outputDir)
	if errors.Is(err, os.ErrNotExist) && !success {
		return nil
	}
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || !ownedByCurrentUser(info) {
		return errors.New("inspector output path must be a producer-created real directory")
	}
	if info.Mode().Perm() != 0700 {
		return errors.New("inspector output directory must be private")
	}
	root, err := os.OpenRoot(outputDir)
	if err != nil {
		return err
	}
	defer root.Close()
	entries, err := os.ReadDir(outputDir)
	if err != nil {
		return err
	}
	allowed := map[string]bool{"summary.json": true, "app-kv.jsonl": true}
	if !success {
		allowed["app-kv.jsonl.tmp"] = true
	}
	var total int64
	seen := make(map[string]bool)
	for _, entry := range entries {
		name := entry.Name()
		if !allowed[name] {
			return fmt.Errorf("unexpected inspector output entry %q", name)
		}
		seen[name] = true
		child, err := root.Lstat(name)
		if err != nil || !child.Mode().IsRegular() {
			return fmt.Errorf("inspector output %q is not a regular file", name)
		}
		st, ok := child.Sys().(*syscall.Stat_t)
		if !ok || st.Nlink != 1 || child.Size() < 0 || child.Size() > limit-total {
			return fmt.Errorf("inspector output %q violates hard file/byte limits", name)
		}
		total += child.Size()
	}
	if success && (!seen["summary.json"] || !seen["app-kv.jsonl"] || len(entries) != 2) {
		return errors.New("successful inspector must produce exactly summary.json and app-kv.jsonl")
	}
	return nil
}

func preflightInspectorEvidence(workspace *os.Root, runID string) error {
	evidence, err := workspace.OpenRoot("evidence")
	if err != nil {
		return fmt.Errorf("open run evidence directory: %w", err)
	}
	defer evidence.Close()
	info, err := evidence.Lstat("inspector")
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 || !ownedByCurrentUser(info) {
		return errors.New("inspector evidence directory must be a privately owned real directory")
	}
	inspector, err := evidence.OpenRoot("inspector")
	if err != nil {
		return err
	}
	defer inspector.Close()
	if _, err := inspector.Lstat(runID); err == nil {
		return errors.New("inspector evidence already exists for this run")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func persistInspectorOutputs(workspace *os.Root, runID, outputDir string, limit int64, result *inspectorExecution) error {
	evidence, err := workspace.OpenRoot("evidence")
	if err != nil {
		return err
	}
	defer evidence.Close()
	if err := evidence.Mkdir("inspector", 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	inspectorInfo, err := evidence.Lstat("inspector")
	if err != nil || !inspectorInfo.IsDir() || inspectorInfo.Mode()&os.ModeSymlink != 0 || inspectorInfo.Mode().Perm() != 0700 || !ownedByCurrentUser(inspectorInfo) {
		return errors.New("inspector evidence directory must be a privately owned real directory")
	}
	inspector, err := evidence.OpenRoot("inspector")
	if err != nil {
		return err
	}
	defer inspector.Close()
	if err := inspector.Mkdir(runID, 0700); err != nil {
		return err
	}
	runInfo, err := inspector.Lstat(runID)
	if err != nil || !runInfo.IsDir() || runInfo.Mode()&os.ModeSymlink != 0 || runInfo.Mode().Perm() != 0700 || !ownedByCurrentUser(runInfo) {
		return errors.New("inspector run evidence directory must be a privately owned real directory")
	}
	runEvidence, err := inspector.OpenRoot(runID)
	if err != nil {
		return err
	}
	defer runEvidence.Close()
	for _, item := range []struct {
		name string
		dst  *coregate.SourceDigest
		path *string
	}{{"summary.json", &result.Summary, &result.RetainedSummary}, {"app-kv.jsonl", &result.ApplicationDump, &result.RetainedDump}, {"app-kv.jsonl.tmp", &result.PartialDumpTemp, &result.RetainedDumpTemp}} {
		digest, present, err := copyInspectorOutput(outputDir, item.name, runEvidence, limit)
		if err != nil {
			return err
		}
		if present {
			*item.dst = digest
			*item.path = filepath.Join("evidence", "inspector", runID, item.name)
		}
	}
	if err := syncRoot(runEvidence); err != nil {
		return err
	}
	if err := syncRoot(inspector); err != nil {
		return err
	}
	return syncRoot(evidence)
}

func copyInspectorOutput(outputDir, name string, dst *os.Root, limit int64) (coregate.SourceDigest, bool, error) {
	source := filepath.Join(outputDir, name)
	fd, err := unix.Open(source, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if errors.Is(err, unix.ENOENT) {
		return coregate.SourceDigest{Path: name}, false, nil
	}
	if err != nil {
		return coregate.SourceDigest{}, false, fmt.Errorf("open inspector output %s without following links: %w", name, err)
	}
	in := os.NewFile(uintptr(fd), source)
	defer in.Close()
	info, err := in.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > limit {
		return coregate.SourceDigest{}, false, fmt.Errorf("inspector output %s is not a bounded regular file", name)
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Nlink != 1 {
		return coregate.SourceDigest{}, false, fmt.Errorf("inspector output %s has unavailable or linked inode identity", name)
	}
	out, err := dst.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return coregate.SourceDigest{}, false, err
	}
	h := sha256.New()
	n, copyErr := io.CopyN(io.MultiWriter(out, h), in, info.Size()+1)
	if n == info.Size() && copyErr == io.EOF {
		copyErr = nil
	}
	if copyErr == nil && n != info.Size() {
		copyErr = errors.New("inspector output changed size during retention copy")
	}
	if copyErr == nil {
		copyErr = out.Sync()
	}
	closeErr := out.Close()
	if copyErr != nil {
		return coregate.SourceDigest{}, false, copyErr
	}
	if closeErr != nil {
		return coregate.SourceDigest{}, false, closeErr
	}
	return coregate.SourceDigest{Path: name, Size: n, SHA256: hex.EncodeToString(h.Sum(nil))}, true, nil
}

func persistInspectorExecution(workspace *os.Root, runID string, result inspectorExecution) error {
	evidence, err := workspace.OpenRoot("evidence")
	if err != nil {
		return fmt.Errorf("open run evidence directory: %w", err)
	}
	defer evidence.Close()
	inspector, err := evidence.OpenRoot("inspector")
	if err != nil {
		return err
	}
	defer inspector.Close()
	runEvidence, err := inspector.OpenRoot(runID)
	if err != nil {
		return err
	}
	defer runEvidence.Close()
	f, err := runEvidence.OpenFile("execution.json", os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	data, marshalErr := json.MarshalIndent(result, "", "  ")
	if marshalErr == nil {
		data = append(data, '\n')
		_, marshalErr = f.Write(data)
	}
	if marshalErr == nil {
		marshalErr = f.Sync()
	}
	closeErr := f.Close()
	if marshalErr != nil {
		return marshalErr
	}
	if closeErr != nil {
		return closeErr
	}
	if err := syncRoot(runEvidence); err != nil {
		return err
	}
	if err := syncRoot(inspector); err != nil {
		return err
	}
	return syncRoot(evidence)
}

func syncRoot(root *os.Root) error {
	f, err := root.Open(".")
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func syncDir(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
