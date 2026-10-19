package input

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

// LocalFixtureAdapter validates a frozen local fixture tree without copying it
// or starting a process. It has no catalog/backend transfer adapter and is not
// evidence that a production export is allowlisted or capture-qualified.
type LocalFixtureAdapter struct {
	Root          string
	SourcePayload []byte
}

func (a LocalFixtureAdapter) Capture(ctx context.Context, binding contract.RunBinding, manifest contract.SourceManifest) (contract.Receipt, error) {
	if err := ctx.Err(); err != nil {
		return contract.Receipt{}, err
	}
	if err := contract.ValidateBinding(binding); err != nil {
		return contract.Receipt{}, err
	}
	if err := ValidateSourceManifest(manifest); err != nil {
		return contract.Receipt{}, err
	}
	if a.Root == "" || !filepath.IsAbs(a.Root) || manifest.RunID != binding.RunID || manifest.ChainID != binding.ChainID || manifest.GenesisSHA256 != binding.GenesisSHA256 {
		return contract.Receipt{}, fmt.Errorf("fixture root or run binding is invalid")
	}
	inputBindingDigest, err := contract.InputBindingDigest(binding)
	if err != nil || manifest.BindingDigest != inputBindingDigest {
		return contract.Receipt{}, fmt.Errorf("fixture manifest input binding digest mismatch")
	}
	if len(a.SourcePayload) == 0 || contract.PayloadDigest(a.SourcePayload) != binding.InputDigests["source_manifest"] {
		return contract.Receipt{}, fmt.Errorf("fixture source payload digest does not match run binding")
	}
	decodedManifest, err := DecodeSourceManifest(contract.SignedDocument{Payload: a.SourcePayload})
	if err != nil {
		return contract.Receipt{}, err
	}
	declaredManifestDigest, err := contract.Digest(decodedManifest)
	if err != nil {
		return contract.Receipt{}, err
	}
	providedManifestDigest, err := contract.Digest(manifest)
	if err != nil || providedManifestDigest != declaredManifestDigest {
		return contract.Receipt{}, fmt.Errorf("fixture manifest differs from signed source payload")
	}
	if !sameHeights(manifest.Heights, binding.Heights) {
		return contract.Receipt{}, fmt.Errorf("fixture manifest heights do not match run binding")
	}
	digest, err := contract.Digest(binding)
	if err != nil {
		return contract.Receipt{}, err
	}
	rootInfo, err := os.Lstat(a.Root)
	resolvedRoot, resolveErr := filepath.EvalSymlinks(a.Root)
	if err != nil || resolveErr != nil || resolvedRoot != filepath.Clean(a.Root) || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 || rootInfo.Mode().Perm() != 0700 {
		return contract.Receipt{}, fmt.Errorf("fixture root must be an existing non-symlink directory")
	}
	root, err := os.OpenRoot(a.Root)
	if err != nil {
		return contract.Receipt{}, err
	}
	defer root.Close()
	pinnedRootInfo, err := root.Stat(".")
	if err != nil || !os.SameFile(rootInfo, pinnedRootInfo) || !pinnedRootInfo.IsDir() {
		return contract.Receipt{}, fmt.Errorf("fixture root identity changed while opening")
	}
	expected := make(map[string]contract.ExportFile, len(manifest.Files))
	for _, file := range manifest.Files {
		expected[file.Path] = file
	}
	seen := make(map[string]bool, len(expected))
	err = fs.WalkDir(root.FS(), ".", func(rel string, entry fs.DirEntry, walkErr error) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if walkErr != nil {
			return walkErr
		}
		if rel == "." {
			return nil
		}
		if !safeRelativePath(rel) {
			return fmt.Errorf("fixture contains an unsafe path")
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("fixture contains symlink")
		}
		if entry.IsDir() {
			if !info.IsDir() || info.Mode().Perm() != 0700 {
				return fmt.Errorf("fixture directory is unsafe or changed during scan")
			}
			return nil
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("fixture contains non-regular file")
		}
		declared, ok := expected[rel]
		if !ok || seen[rel] {
			return fmt.Errorf("fixture contains unlisted or duplicate file")
		}
		seen[rel] = true
		return verifyFixtureFile(ctx, root, rel, info, declared)
	})
	if err != nil {
		return contract.Receipt{}, err
	}
	if len(seen) != len(expected) {
		return contract.Receipt{}, fmt.Errorf("fixture is missing declared files")
	}
	manifestDigest, err := contract.Digest(manifest)
	if err != nil {
		return contract.Receipt{}, err
	}
	exit := 0
	return contract.Receipt{
		SchemaVersion: contract.Version, RunID: binding.RunID, BindingDigest: digest,
		Phase: contract.Capture, Operation: "validate_local_fixture_only", State: contract.Succeeded,
		Sequence: 1, EvidenceDigests: map[string]string{"source_manifest": manifestDigest},
		ExitCode: &exit, Reason: "fixture hashes verified locally; no file was transferred",
	}, nil
}

func verifyFixtureFile(ctx context.Context, root *os.Root, rel string, before os.FileInfo, declared contract.ExportFile) error {
	if before.Mode().Perm() != 0600 {
		return fmt.Errorf("fixture file permissions are too broad")
	}
	if nlink, ok := linkCount(before); !ok || nlink != 1 {
		return fmt.Errorf("fixture file link count is not verifiably one")
	}
	file, err := root.Open(rel)
	if err != nil {
		return err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(before, opened) || !opened.Mode().IsRegular() || opened.Mode().Perm() != 0600 {
		return fmt.Errorf("fixture file identity changed while opening")
	}
	if opened.Size() != declared.Size {
		return fmt.Errorf("fixture file size mismatch")
	}
	hash := sha256.New()
	buffer := make([]byte, 64*1024)
	var read int64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		count, readErr := file.Read(buffer)
		if count > 0 {
			read += int64(count)
			if read > declared.Size {
				return fmt.Errorf("fixture file exceeds declared size")
			}
			_, _ = hash.Write(buffer[:count])
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	after, err := file.Stat()
	if err != nil || !os.SameFile(opened, after) || !after.Mode().IsRegular() || after.Mode().Perm() != 0600 || after.Size() != opened.Size() || after.ModTime() != opened.ModTime() {
		return fmt.Errorf("fixture file changed while reading")
	}
	if nlink, ok := linkCount(after); !ok || nlink != 1 {
		return fmt.Errorf("fixture file link count changed or is unverifiable")
	}
	if read != declared.Size {
		return fmt.Errorf("fixture file read was incomplete")
	}
	if hex.EncodeToString(hash.Sum(nil)) != declared.SHA256 {
		return fmt.Errorf("fixture file digest mismatch")
	}
	return nil
}

func linkCount(info os.FileInfo) (uint64, bool) {
	system := reflect.ValueOf(info.Sys())
	if !system.IsValid() {
		return 0, false
	}
	if system.Kind() == reflect.Pointer {
		system = system.Elem()
	}
	if system.Kind() != reflect.Struct {
		return 0, false
	}
	field := system.FieldByName("Nlink")
	if !field.IsValid() {
		return 0, false
	}
	switch field.Kind() {
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return field.Uint(), true
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if field.Int() < 0 {
			return 0, false
		}
		return uint64(field.Int()), true
	default:
		return 0, false
	}
}
