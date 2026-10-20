// Package capture copies an operator-frozen export into a private local tree.
// It does not authenticate a manifest or qualify a catalog.
package capture

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/catalog"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/input"
	"golang.org/x/sys/unix"
)

var ErrUnsafePath = errors.New("unsafe capture path or file")

// Policy must be supplied by a separately qualified catalog adapter. A signed
// source inventory alone is deliberately insufficient to authorize components.
type Policy struct {
	AllowedComponents []string
	AllowedFiles      []string
	ExpectedFiles     []contract.ExportFile
	Backend           string
	Layout            string
	BackendVersion    string
	MaxBytes          int64
	ReserveBytes      int64
}

// PolicyFromVerifiedArtifact projects an already verified recovery artifact
// into the exact file/component allowlist used during local transfer.
func PolicyFromVerifiedArtifact(a catalog.RecoveryArtifact, b contract.RunBinding, maxBytes, reserveBytes int64) (Policy, error) {
	p := Policy{Backend: a.Backend, Layout: a.Layout, BackendVersion: a.BackendVersion, MaxBytes: maxBytes, ReserveBytes: reserveBytes}
	if a.ScenarioID == "" || len(a.Files) == 0 || !sameHeights(a.Heights, b.Heights) || a.FirstRepairedBlock != b.Heights.FirstRepaired {
		return p, errors.New("verified artifact does not match run heights or has no exact inventory")
	}
	components := map[string]bool{}
	seen := map[string]bool{}
	for _, f := range a.Files {
		if !safePath(f.Path) || seen[f.Path] || !contract.IsDigest(f.SHA256) || f.Size < 0 || f.Component == "" {
			return p, errors.New("verified artifact has invalid file policy")
		}
		seen[f.Path] = true
		components[f.Component] = true
		p.AllowedFiles = append(p.AllowedFiles, f.Path)
		p.ExpectedFiles = append(p.ExpectedFiles, contract.ExportFile{Path: f.Path, SHA256: f.SHA256, Size: f.Size})
	}
	for c := range components {
		p.AllowedComponents = append(p.AllowedComponents, c)
	}
	return p, validatePolicyBounds(p)
}

type Adapter struct {
	Root, Destination    string
	Policy               Policy
	SourcePayload        []byte
	SourceDocument       contract.SignedDocument
	SourcePolicy         input.VerificationPolicy
	Approval             contract.SignedDocument
	ApprovalPolicy       input.VerificationPolicy
	FreezePayload        []byte
	LayoutPayload        []byte
	InventoryPayload     []byte
	WitnessPayloads      [][]byte
	OfflineReaderPayload []byte
	Verifier             ProofVerifier
	SyncParent           func(string) error
}

type copyOps struct {
	syncFile        func(*os.File) error
	syncDestination func(*os.Root) error
	syncParent      func(*os.Root, string) error
	available       func(string) (int64, error)
	afterOpenSource func() error
	afterInventory  func() error
	afterOpenParent func() error
	afterCopy       func() error
	wrapWriter      func(io.Writer) io.Writer
}

type Result struct {
	Files          []contract.ExportFile `json:"files"`
	Bytes          int64                 `json:"bytes"`
	ManifestSHA256 string                `json:"manifest_sha256"`
	PayloadSHA256  string                `json:"payload_sha256"`
}

// Copy transfers only the exact regular files in a frozen manifest. On errors
// after transfer starts, already copied bytes are retained for investigation.
func Copy(ctx context.Context, sourceDir, destinationDir string, manifest contract.SourceManifest, policy Policy) (Result, error) {
	return copyWithOps(ctx, sourceDir, destinationDir, manifest, policy, copyOps{syncFile: func(f *os.File) error { return f.Sync() }, syncDestination: syncTree, syncParent: func(r *os.Root, _ string) error { return syncRootHandle(r) }, available: availableBytes})
}

func copyWithOps(ctx context.Context, sourceDir, destinationDir string, manifest contract.SourceManifest, policy Policy, ops copyOps) (result Result, retErr error) {
	h := sha256.New()
	defer func() {
		result.PayloadSHA256 = hex.EncodeToString(h.Sum(nil))
		result.ManifestSHA256, _ = contract.Digest(manifest)
	}()
	if err := validatePolicy(manifest, policy); err != nil {
		return result, err
	}
	if sourceDir == "" || destinationDir == "" || !filepath.IsAbs(sourceDir) || !filepath.IsAbs(destinationDir) || filepath.Clean(sourceDir) != sourceDir || filepath.Clean(destinationDir) != destinationDir || sourceDir == destinationDir || within(sourceDir, destinationDir) || within(destinationDir, sourceDir) {
		return result, fmt.Errorf("source and destination must be distinct clean absolute paths")
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	src, err := os.OpenRoot(sourceDir)
	if err != nil {
		return result, err
	}
	defer src.Close()
	if ops.afterOpenSource != nil {
		if err := ops.afterOpenSource(); err != nil {
			return result, err
		}
	}
	if err := sameOpenDirectory(src, sourceDir, true); err != nil {
		return result, err
	}
	sourceFiles, err := validateSourceTree(src, manifest.Files)
	if err != nil {
		return result, err
	}
	if ops.afterInventory != nil {
		if err := ops.afterInventory(); err != nil {
			return result, err
		}
	}
	parentPath, base := filepath.Dir(destinationDir), filepath.Base(destinationDir)
	parentInfo, err := os.Lstat(parentPath)
	if err != nil || !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 || !ownedSecureDirectory(parentInfo) {
		return result, fmt.Errorf("destination parent must exist as a real directory")
	}
	var total int64
	for _, f := range manifest.Files {
		if f.Size > policy.MaxBytes-total {
			return result, fmt.Errorf("capture quota exceeded")
		}
		total += f.Size
	}
	free, err := ops.available(parentPath)
	if err != nil {
		return result, fmt.Errorf("check capture free space: %w", err)
	}
	if total > free || policy.ReserveBytes > free-total {
		return result, fmt.Errorf("insufficient capture space: need %d bytes plus %d reserve, have %d", total, policy.ReserveBytes, free)
	}
	parent, err := os.OpenRoot(parentPath)
	if err != nil {
		return result, err
	}
	defer parent.Close()
	if ops.afterOpenParent != nil {
		if e := ops.afterOpenParent(); e != nil {
			return result, e
		}
	}
	check, err := parent.Open(".")
	if err != nil {
		return result, err
	}
	checkInfo, err := check.Stat()
	check.Close()
	currentParent, statErr := os.Lstat(parentPath)
	if err != nil || statErr != nil || !os.SameFile(parentInfo, checkInfo) || !os.SameFile(currentParent, checkInfo) || currentParent.Mode()&os.ModeSymlink != 0 {
		return result, ErrUnsafePath
	}
	if err := parent.Mkdir(base, 0o700); err != nil {
		return result, err
	}
	dst, err := parent.OpenRoot(base)
	if err != nil {
		return result, err
	}
	defer dst.Close()
	if err := sameOpenDirectory(dst, destinationDir, false); err != nil {
		return result, err
	}
	ordered := append([]contract.ExportFile(nil), manifest.Files...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Path < ordered[j].Path })
	for _, item := range ordered {
		if err := ctx.Err(); err != nil {
			result.Bytes = totalCopied(result.Files)
			return result, err
		}
		if err := makeParents(dst, path.Dir(item.Path)); err != nil {
			result.Bytes = totalCopied(result.Files)
			return result, err
		}
		in, err := src.OpenFile(item.Path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
		if err != nil {
			result.Bytes = totalCopied(result.Files)
			return result, err
		}
		info, err := in.Stat()
		if err != nil {
			in.Close()
			return result, err
		}
		if !info.Mode().IsRegular() || !singleLink(info) || info.Size() != item.Size {
			in.Close()
			return result, fmt.Errorf("%w: %s", ErrUnsafePath, item.Path)
		}
		if !os.SameFile(sourceFiles[item.Path], info) {
			in.Close()
			return result, fmt.Errorf("source inode changed after inventory: %s", item.Path)
		}
		out, err := dst.OpenFile(item.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0o600)
		if err != nil {
			in.Close()
			return result, err
		}
		fh := sha256.New()
		writer := io.Writer(io.MultiWriter(out, fh, h))
		if ops.wrapWriter != nil {
			writer = ops.wrapWriter(writer)
		}
		n, copyErr := copyContext(ctx, writer, in)
		result.Bytes = totalCopied(result.Files) + n
		closeIn := in.Close()
		syncErr := ops.syncFile(out)
		closeOut := out.Close()
		if copyErr != nil {
			result.Bytes = totalCopied(result.Files) + n
			return result, copyErr
		}
		if closeIn != nil {
			return result, closeIn
		}
		if syncErr != nil {
			return result, syncErr
		}
		if closeOut != nil {
			return result, closeOut
		}
		if n != item.Size || hex.EncodeToString(fh.Sum(nil)) != item.SHA256 {
			return result, fmt.Errorf("capture content differs from frozen inventory: %s", item.Path)
		}
		result.Files = append(result.Files, item)
		result.Bytes = totalCopied(result.Files)
	}
	if err := ops.syncDestination(dst); err != nil {
		return result, err
	}
	if err := ops.syncParent(parent, parentPath); err != nil {
		return result, fmt.Errorf("sync destination parent: %w", err)
	}
	if err := sameParentPath(parent, parentPath); err != nil {
		return result, err
	}
	if ops.afterCopy != nil {
		if err := ops.afterCopy(); err != nil {
			return result, err
		}
	}
	if _, err := validateSourceTree(src, manifest.Files); err != nil {
		return result, fmt.Errorf("source export changed during capture: %w", err)
	}
	if err := verifySourceContent(ctx, src, manifest.Files, sourceFiles); err != nil {
		return result, fmt.Errorf("source export changed during capture: %w", err)
	}
	result.Bytes = total
	return result, nil
}

func validatePolicy(m contract.SourceManifest, p Policy) error {
	if !m.Frozen || len(m.Files) == 0 || len(m.Components) == 0 || p.MaxBytes <= 0 || p.ReserveBytes < 0 {
		return errors.New("frozen manifest and positive quota policy are required")
	}
	allowed := map[string]bool{}
	for _, c := range p.AllowedComponents {
		if c == "" || allowed[c] {
			return errors.New("invalid component policy")
		}
		allowed[c] = true
	}
	if len(allowed) == 0 {
		return errors.New("explicit component policy is required")
	}
	if p.Backend == "" || p.Layout == "" || p.BackendVersion == "" {
		return errors.New("capture policy snapshot identity is incomplete")
	}
	files := map[string]bool{}
	for _, f := range p.AllowedFiles {
		if !safePath(f) || files[f] {
			return errors.New("invalid exact-file policy")
		}
		files[f] = true
	}
	if len(files) == 0 || len(files) != len(m.Files) {
		return errors.New("exact-file policy must match manifest inventory")
	}
	manifestComponents := map[string]bool{}
	for _, c := range m.Components {
		if manifestComponents[c] {
			return errors.New("duplicate manifest component")
		}
		if !allowed[c] {
			return fmt.Errorf("component is not allowed by capture policy: %s", c)
		}
		manifestComponents[c] = true
	}
	if len(manifestComponents) != len(allowed) {
		return errors.New("manifest component inventory differs from exact capture policy")
	}
	if len(p.ExpectedFiles) > 0 {
		if len(p.ExpectedFiles) != len(m.Files) {
			return errors.New("manifest inventory differs from artifact inventory")
		}
		expected := map[string]contract.ExportFile{}
		for _, f := range p.ExpectedFiles {
			if _, ok := expected[f.Path]; ok {
				return errors.New("duplicate artifact inventory path")
			}
			expected[f.Path] = f
		}
		for _, f := range m.Files {
			if e, ok := expected[f.Path]; !ok || e.SHA256 != f.SHA256 || e.Size != f.Size {
				return fmt.Errorf("manifest file differs from verified artifact: %s", f.Path)
			}
		}
	}
	seen := map[string]bool{}
	var sum int64
	for _, f := range m.Files {
		if !safePath(f.Path) || seen[f.Path] || !contract.IsDigest(f.SHA256) || f.Size < 0 {
			return fmt.Errorf("%w: invalid inventory entry", ErrUnsafePath)
		}
		seen[f.Path] = true
		if !files[f.Path] {
			return fmt.Errorf("file is not allowed by capture policy: %s", f.Path)
		}
		if f.Size > p.MaxBytes-sum {
			return errors.New("capture quota exceeded")
		}
		sum += f.Size
	}
	if m.Backend != p.Backend || m.Layout != p.Layout || m.BackendVersion != p.BackendVersion {
		return errors.New("manifest snapshot identity differs from capture policy")
	}
	return nil
}
func validatePolicyBounds(p Policy) error {
	if p.MaxBytes <= 0 || p.ReserveBytes < 0 {
		return errors.New("capture quota policy is invalid")
	}
	return nil
}
func safePath(s string) bool {
	if s == "" || strings.Contains(s, `\`) || path.IsAbs(s) || path.Clean(s) != s || s == "." {
		return false
	}
	for _, p := range strings.Split(s, "/") {
		if p == "" || p == ".." || p == "." {
			return false
		}
		low := strings.ToLower(p)
		for _, bad := range []string{"key", "signer", "tmkms", "secret", "credential", "ssh", ".env", "gateway", "ml-"} {
			if strings.Contains(low, bad) {
				return false
			}
		}
	}
	return true
}
func safeDirectory(p string, dest bool) error {
	i, e := os.Lstat(p)
	if e != nil {
		return e
	}
	if !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	}
	st, ok := i.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() {
		return ErrUnsafePath
	}
	if dest && i.Mode().Perm()&0o077 != 0 {
		return ErrUnsafePath
	}
	return nil
}
func ownedSecureDirectory(info os.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid() && info.Mode().Perm()&0o022 == 0
}
func sameOpenDirectory(r *os.Root, p string, source bool) error {
	pathInfo, e := os.Lstat(p)
	if e != nil {
		return e
	}
	f, e := r.Open(".")
	if e != nil {
		return e
	}
	defer f.Close()
	handleInfo, e := f.Stat()
	if e != nil {
		return e
	}
	if !pathInfo.IsDir() || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(pathInfo, handleInfo) {
		return ErrUnsafePath
	}
	st, ok := handleInfo.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Getuid() {
		return ErrUnsafePath
	}
	if !source && handleInfo.Mode().Perm()&0o077 != 0 {
		return ErrUnsafePath
	}
	return nil
}
func singleLink(i os.FileInfo) bool { st, ok := i.Sys().(*syscall.Stat_t); return ok && st.Nlink == 1 }
func validateSourceTree(root *os.Root, files []contract.ExportFile) (map[string]os.FileInfo, error) {
	allowed := map[string]bool{}
	for _, f := range files {
		allowed[f.Path] = true
	}
	found := map[string]os.FileInfo{}
	dirs := map[string]bool{".": true}
	var walk func(string) error
	walk = func(dir string) error {
		entries, e := rootReadDir(root, dir)
		if e != nil {
			return e
		}
		for _, entry := range entries {
			rel := entry.Name()
			if dir != "." {
				rel = dir + "/" + rel
			}
			info, e := root.Lstat(rel)
			if e != nil {
				return e
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("%w: symlink %s", ErrUnsafePath, rel)
			}
			if info.IsDir() {
				dirs[rel] = true
				if e := walk(rel); e != nil {
					return e
				}
				continue
			}
			if !info.Mode().IsRegular() || !singleLink(info) {
				return fmt.Errorf("%w: nonregular or hardlinked entry %s", ErrUnsafePath, rel)
			}
			if !allowed[rel] {
				return fmt.Errorf("unlisted export file %s", rel)
			}
			found[rel] = info
		}
		return nil
	}
	if e := walk("."); e != nil {
		return nil, e
	}
	for d := range dirs {
		if d == "." {
			continue
		}
		used := false
		for f := range allowed {
			if strings.HasPrefix(f, d+"/") {
				used = true
				break
			}
		}
		if !used {
			return nil, fmt.Errorf("unlisted empty directory %s", d)
		}
	}
	if len(found) != len(allowed) {
		return nil, errors.New("source export is missing inventory files")
	}
	return found, nil
}
func verifySourceContent(ctx context.Context, root *os.Root, files []contract.ExportFile, initial map[string]os.FileInfo) error {
	for _, item := range files {
		if err := ctx.Err(); err != nil {
			return err
		}
		f, e := root.OpenFile(item.Path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
		if e != nil {
			return e
		}
		before, e := f.Stat()
		if e != nil {
			f.Close()
			return e
		}
		if !before.Mode().IsRegular() || !singleLink(before) || !os.SameFile(initial[item.Path], before) || before.Size() != item.Size {
			f.Close()
			return ErrUnsafePath
		}
		h := sha256.New()
		n, e := copyContext(ctx, h, f)
		after, statErr := f.Stat()
		closeErr := f.Close()
		if e != nil {
			return e
		}
		if statErr != nil {
			return statErr
		}
		if closeErr != nil {
			return closeErr
		}
		if n != item.Size || hex.EncodeToString(h.Sum(nil)) != item.SHA256 || !os.SameFile(before, after) || before.Size() != after.Size() {
			return fmt.Errorf("source file changed: %s", item.Path)
		}
	}
	return nil
}
func makeParents(r *os.Root, p string) error {
	if p == "." {
		return nil
	}
	parts := strings.Split(p, "/")
	cur := ""
	for _, part := range parts {
		if cur != "" {
			cur += "/"
		}
		cur += part
		if e := r.Mkdir(cur, 0o700); e != nil && !errors.Is(e, os.ErrExist) {
			return e
		}
		i, e := r.Lstat(cur)
		if e != nil || !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
			return ErrUnsafePath
		}
	}
	return nil
}
func copyContext(ctx context.Context, w io.Writer, r io.Reader) (int64, error) {
	b := make([]byte, 128*1024)
	var n int64
	for {
		if err := ctx.Err(); err != nil {
			return n, err
		}
		nr, er := r.Read(b)
		if nr > 0 {
			nw, ew := w.Write(b[:nr])
			n += int64(nw)
			if ew != nil {
				return n, ew
			}
			if nw != nr {
				return n, io.ErrShortWrite
			}
		}
		if er == io.EOF {
			return n, nil
		}
		if er != nil {
			return n, er
		}
	}
}
func syncDirectory(r *os.Root) error {
	d, e := r.Open(".")
	if e != nil {
		return e
	}
	defer d.Close()
	return d.Sync()
}
func syncTree(r *os.Root) error {
	var walk func(string) error
	walk = func(dir string) error {
		entries, e := rootReadDir(r, dir)
		if e != nil {
			return e
		}
		for _, entry := range entries {
			if entry.IsDir() {
				name := entry.Name()
				if dir != "." {
					name = dir + "/" + name
				}
				if e = walk(name); e != nil {
					return e
				}
			}
		}
		f, e := r.Open(dir)
		if e != nil {
			return e
		}
		defer f.Close()
		return f.Sync()
	}
	return walk(".")
}
func rootReadDir(r *os.Root, p string) ([]os.DirEntry, error) {
	f, e := r.Open(p)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	return f.ReadDir(-1)
}
func syncRootHandle(r *os.Root) error {
	d, e := r.Open(".")
	if e != nil {
		return e
	}
	defer d.Close()
	return d.Sync()
}
func availableBytes(p string) (int64, error) {
	var stat unix.Statfs_t
	if e := unix.Statfs(p, &stat); e != nil {
		return 0, e
	}
	if stat.Bsize <= 0 {
		return 0, errors.New("invalid filesystem block size")
	}
	max := uint64(^uint64(0) >> 1)
	if stat.Bavail > max/uint64(stat.Bsize) {
		return int64(max), nil
	}
	return int64(stat.Bavail * uint64(stat.Bsize)), nil
}
func sameParentPath(r *os.Root, p string) error {
	pathInfo, e := os.Lstat(p)
	if e != nil {
		return e
	}
	f, e := r.Open(".")
	if e != nil {
		return e
	}
	defer f.Close()
	i, e := f.Stat()
	if e != nil {
		return e
	}
	if !os.SameFile(pathInfo, i) || pathInfo.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	}
	return nil
}
func totalCopied(fs []contract.ExportFile) int64 {
	var n int64
	for _, f := range fs {
		n += f.Size
	}
	return n
}

func within(parent, child string) bool {
	rel, e := filepath.Rel(parent, child)
	return e == nil && (rel == "." || rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

func (a Adapter) Capture(ctx context.Context, b contract.RunBinding, m contract.SourceManifest) (contract.Receipt, error) {
	ops := copyOps{syncFile: func(f *os.File) error { return f.Sync() }, syncDestination: syncTree, available: availableBytes, syncParent: func(r *os.Root, p string) error {
		if a.SyncParent != nil {
			return a.SyncParent(p)
		}
		return syncRootHandle(r)
	}}
	return a.captureWithOps(ctx, b, m, ops)
}

func (a Adapter) captureWithOps(ctx context.Context, b contract.RunBinding, m contract.SourceManifest, ops copyOps) (contract.Receipt, error) {
	r := contract.Receipt{SchemaVersion: contract.Version, RunID: b.RunID, Phase: contract.Capture, Operation: "frozen_export_copy", State: contract.Failed, Sequence: 1, EvidenceDigests: map[string]string{}}
	if err := contract.ValidateBinding(b); err != nil {
		return r, fmt.Errorf("invalid run binding: %w", err)
	}
	d, e := contract.Digest(b)
	if e != nil {
		return r, e
	}
	r.BindingDigest = d
	if len(a.SourcePayload) == 0 {
		return r, errors.New("exact signed source payload is required")
	}
	if b.InputDigests["source_manifest"] != contract.PayloadDigest(a.SourcePayload) {
		return r, errors.New("source payload digest differs from run binding")
	}
	var payloadManifest contract.SourceManifest
	if err := contract.DecodeStrict(a.SourcePayload, &payloadManifest); err != nil {
		return r, fmt.Errorf("decode source payload: %w", err)
	}
	want, _ := json.Marshal(m)
	got, _ := json.Marshal(payloadManifest)
	if string(want) != string(got) {
		return r, errors.New("typed source manifest differs from exact signed payload")
	}
	if a.SourceDocument.Payload == nil || string(a.SourceDocument.Payload) != string(a.SourcePayload) {
		return r, errors.New("source signed document must contain the exact source payload")
	}
	if m.SchemaVersion != contract.Version || m.Kind != "source_manifest" || m.Scope != "capture" || m.RunID != b.RunID || m.ChainID != b.ChainID || m.GenesisSHA256 != b.GenesisSHA256 {
		return r, errors.New("source manifest identity differs from run binding")
	}
	inputBinding, err := contract.InputBindingDigest(b)
	if err != nil || m.BindingDigest != inputBinding {
		return r, errors.New("source manifest binding digest mismatch")
	}
	if !sameHeights(m.Heights, b.Heights) {
		return r, errors.New("source manifest heights differ from run binding")
	}
	boundDest, ok := b.Paths["source"]
	if !ok || filepath.Clean(a.Destination) != boundDest || !within(b.Workspace, a.Destination) || filepath.Clean(a.Root) != filepath.Clean(b.Paths["export"]) {
		return r, errors.New("capture paths do not match bound workspace paths")
	}
	parent := filepath.Dir(a.Destination)
	pi, err := os.Lstat(parent)
	if err != nil || !pi.IsDir() || pi.Mode()&os.ModeSymlink != 0 || !ownedSecureDirectory(pi) {
		return r, errors.New("bound destination parent must already exist as a directory")
	}
	r.EvidenceDigests["source_payload_sha256"] = contract.PayloadDigest(a.SourcePayload)
	if a.SourcePolicy.Kind != "source_manifest" || a.SourcePolicy.Scope != "capture" || a.SourcePolicy.Role != "archive_owner" {
		return r, errors.New("source manifest trust policy must be pinned to source_manifest/capture/archive_owner")
	}
	sourcePolicyBinding, err := contract.Digest(a.SourcePolicy.Binding)
	if err != nil || sourcePolicyBinding != d {
		return r, errors.New("source manifest trust policy is bound to another run")
	}
	verifiedManifest, err := input.VerifySourceManifest(a.SourceDocument, a.SourcePolicy)
	if err != nil {
		return r, fmt.Errorf("verify signed source manifest: %w", err)
	}
	verifiedBytes, _ := json.Marshal(verifiedManifest)
	if string(verifiedBytes) != string(want) {
		return r, errors.New("typed source manifest differs from verified signed source document")
	}
	if err := a.verifyAuthorization(ctx, b, m, &r); err != nil {
		r.Reason = err.Error()
		return r, err
	}
	result, e := copyWithOps(ctx, a.Root, a.Destination, m, a.Policy, ops)
	if e != nil {
		if result.Bytes > 0 {
			r.EvidenceDigests["partial_payload_sha256"] = result.PayloadSHA256
			r.EvidenceDigests["manifest_sha256"] = result.ManifestSHA256
		}
		if errors.Is(e, context.Canceled) || errors.Is(e, context.DeadlineExceeded) {
			r.State = contract.Unknown
		}
		r.Reason = e.Error()
		return r, e
	}
	r.State = contract.Succeeded
	r.EvidenceDigests["manifest_sha256"] = result.ManifestSHA256
	r.EvidenceDigests["payload_sha256"] = result.PayloadSHA256
	return r, nil
}

func (a Adapter) verifyAuthorization(ctx context.Context, b contract.RunBinding, m contract.SourceManifest, r *contract.Receipt) error {
	if a.ApprovalPolicy.Kind != "approval" || a.ApprovalPolicy.Scope != "capture" || a.ApprovalPolicy.Role != "operator" {
		return errors.New("capture approval verifier policy must be pinned to approval/capture/operator")
	}
	policyBindingDigest, err := contract.Digest(a.ApprovalPolicy.Binding)
	if err != nil {
		return err
	}
	bindingDigest, err := contract.Digest(b)
	if err != nil {
		return err
	}
	if policyBindingDigest != bindingDigest {
		return errors.New("capture approval trust policy is bound to another run")
	}
	approvalDigest := contract.PayloadDigest(a.Approval.Payload)
	if len(a.Approval.Payload) == 0 || b.InputDigests["capture_approval"] != approvalDigest {
		return errors.New("capture approval payload is absent or differs from capture_approval input digest")
	}
	policy := a.ApprovalPolicy
	policy.Binding = b
	policy.Binding.InputDigests = cloneInputDigests(b.InputDigests)
	policy.Binding.InputDigests["approval"] = approvalDigest
	if _, err := input.VerifyDocument(a.Approval, policy); err != nil {
		return fmt.Errorf("verify scoped capture approval: %w", err)
	}
	for name, raw := range map[string][]byte{"snapshot_freeze": a.FreezePayload, "layout_proof": a.LayoutPayload, "inventory_receipt": a.InventoryPayload, "offline_reader": a.OfflineReaderPayload} {
		if len(raw) == 0 || b.InputDigests[name] != contract.PayloadDigest(raw) {
			return fmt.Errorf("%s proof is absent or differs from run input digest", name)
		}
	}
	if len(a.WitnessPayloads) != 2 {
		return errors.New("exactly two raw witness proofs are required")
	}
	for i, raw := range a.WitnessPayloads {
		name := fmt.Sprintf("witness_%d", i+1)
		if len(raw) == 0 || b.InputDigests[name] != contract.PayloadDigest(raw) {
			return fmt.Errorf("%s proof is absent or differs from run input digest", name)
		}
	}
	if err := verifySnapshot(a.Verifier, ctx, b, m, a.FreezePayload, a.LayoutPayload, a.InventoryPayload); err != nil {
		return err
	}
	if err := verifyWitnesses(a.Verifier, ctx, b, a.WitnessPayloads); err != nil {
		return err
	}
	if err := verifyOfflineReader(a.Verifier, ctx, b, m.SnapshotID, a.OfflineReaderPayload); err != nil {
		return err
	}
	r.EvidenceDigests["capture_approval_sha256"] = approvalDigest
	r.EvidenceDigests["snapshot_freeze_sha256"] = contract.PayloadDigest(a.FreezePayload)
	r.EvidenceDigests["layout_proof_sha256"] = contract.PayloadDigest(a.LayoutPayload)
	r.EvidenceDigests["inventory_receipt_sha256"] = contract.PayloadDigest(a.InventoryPayload)
	r.EvidenceDigests["witness_1_sha256"] = contract.PayloadDigest(a.WitnessPayloads[0])
	r.EvidenceDigests["witness_2_sha256"] = contract.PayloadDigest(a.WitnessPayloads[1])
	r.EvidenceDigests["offline_reader_sha256"] = contract.PayloadDigest(a.OfflineReaderPayload)
	return nil
}
func cloneInputDigests(src map[string]string) map[string]string {
	out := make(map[string]string, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func sameHeights(a, b contract.Heights) bool {
	return a.Blockstore == b.Blockstore && a.App == b.App && a.FirstRepaired == b.FirstRepaired && a.Consensus != nil && b.Consensus != nil && *a.Consensus == *b.Consensus
}
