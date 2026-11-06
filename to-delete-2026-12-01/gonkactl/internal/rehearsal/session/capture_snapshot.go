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
	"path"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/sys/unix"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/evidence"
)

const topologyBeforeSnapshotFile = "snapshot-topology-before.json"

// captureTopologySnapshot pins a validated logical snapshot to the exact
// source manifest and source inventory, while checking that a reader neither
// replaced the copied source nor mutated its contents.
func captureTopologySnapshot(ctx context.Context, binding contract.RunBinding, manifest contract.SourceManifest, reader SnapshotReader) (string, error) {
	if ctx == nil || reader == nil {
		return "", errors.New("logical snapshot reader is unavailable")
	}
	source := binding.Paths["source"]
	if source == "" || !filepath.IsAbs(source) || filepath.Clean(source) != source || !withinWorkspace(binding.Workspace, source) {
		return "", errors.New("logical snapshot source is not the bound run source path")
	}
	if !contract.IsDigest(binding.InputDigests["source_manifest"]) {
		return "", errors.New("source manifest digest is not pinned in run binding")
	}
	root, rootInfo, err := openCopiedSourceRoot(source)
	if err != nil {
		return "", err
	}
	defer root.Close()
	before, err := verifyCopiedInventory(root, source, rootInfo, manifest.Files, nil)
	if err != nil {
		return "", fmt.Errorf("verify copied source before logical read: %w", err)
	}
	readerBinding, err := cloneSnapshotBinding(binding)
	if err != nil {
		return "", err
	}
	var snapshot contract.Snapshot
	if manifestReader, ok := reader.(ManifestSnapshotReader); ok {
		// Deep-copy the authenticated inventory: a reader must not be able to
		// change the manifest used for the post-inspection source check.
		manifestRaw, marshalErr := json.Marshal(manifest)
		if marshalErr != nil {
			return "", marshalErr
		}
		var readerManifest contract.SourceManifest
		if err := contract.DecodeStrict(manifestRaw, &readerManifest); err != nil {
			return "", err
		}
		snapshot, err = manifestReader.ReadManifestSnapshot(ctx, readerBinding, readerManifest)
	} else {
		snapshot, err = reader.ReadSnapshot(ctx, readerBinding)
	}
	if err != nil {
		return "", fmt.Errorf("read logical snapshot from bound copied source: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	logicalDigest, err := evidence.SnapshotDigest(snapshot)
	if err != nil {
		return "", fmt.Errorf("validate logical snapshot: %w", err)
	}
	if _, err := verifyCopiedInventory(root, source, rootInfo, manifest.Files, before); err != nil {
		return "", fmt.Errorf("copied source changed during logical read: %w", err)
	}
	evidencePayload, err := json.Marshal(snapshot)
	if err != nil {
		return "", err
	}
	evidencePayload = append(evidencePayload, '\n')
	if len(evidencePayload) > maxFileSize {
		return "", errors.New("logical snapshot evidence exceeds size limit")
	}
	if err := writeEvidenceFiles(binding.Workspace, map[string][]byte{topologyBeforeSnapshotFile: evidencePayload}); err != nil {
		return "", fmt.Errorf("persist logical snapshot evidence: %w", err)
	}
	if _, err := verifyCopiedInventory(root, source, rootInfo, manifest.Files, before); err != nil {
		return "", fmt.Errorf("copied source changed during logical read: %w", err)
	}
	return logicalDigest, nil
}

func withinWorkspace(workspace, source string) bool {
	if !filepath.IsAbs(workspace) || filepath.Clean(workspace) != workspace {
		return false
	}
	rel, err := filepath.Rel(workspace, source)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func cloneSnapshotBinding(binding contract.RunBinding) (contract.RunBinding, error) {
	copy := binding
	copy.InputDigests = cloneInputDigests(binding.InputDigests)
	copy.RuntimeIdentities = make(map[string]string, len(binding.RuntimeIdentities))
	for key, value := range binding.RuntimeIdentities {
		copy.RuntimeIdentities[key] = value
	}
	copy.Paths = make(map[string]string, len(binding.Paths))
	for key, value := range binding.Paths {
		copy.Paths[key] = value
	}
	if binding.Heights.Consensus != nil {
		height := *binding.Heights.Consensus
		copy.Heights.Consensus = &height
	}
	if err := contract.ValidateBinding(copy); err != nil {
		return contract.RunBinding{}, err
	}
	return copy, nil
}

func openCopiedSourceRoot(source string) (*os.Root, os.FileInfo, error) {
	info, err := os.Lstat(source)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 || !ownedByCurrentUser(info) {
		return nil, nil, errors.New("copied source must be a privately owned real directory")
	}
	root, err := os.OpenRoot(source)
	if err != nil {
		return nil, nil, err
	}
	opened, err := root.Stat(".")
	if err != nil || !os.SameFile(info, opened) {
		root.Close()
		return nil, nil, errors.New("copied source directory identity changed")
	}
	return root, info, nil
}

func verifyCopiedInventory(root *os.Root, source string, rootInfo os.FileInfo, inventory []contract.ExportFile, prior map[string]os.FileInfo) (map[string]os.FileInfo, error) {
	if len(inventory) == 0 {
		return nil, errors.New("signed source inventory is empty")
	}
	pathSet := map[string]contract.ExportFile{}
	for _, item := range inventory {
		if !safeSnapshotFilePath(item.Path) || item.Size < 0 || !contract.IsDigest(item.SHA256) {
			return nil, errors.New("signed source inventory contains an invalid entry")
		}
		if _, exists := pathSet[item.Path]; exists {
			return nil, errors.New("signed source inventory contains duplicate paths")
		}
		pathSet[item.Path] = item
	}
	found := map[string]os.FileInfo{}
	directories := map[string]bool{".": true}
	var walk func(string) error
	walk = func(dir string) error {
		f, err := root.Open(dir)
		if err != nil {
			return err
		}
		entries, readErr := f.ReadDir(-1)
		closeErr := f.Close()
		if readErr != nil {
			return readErr
		}
		if closeErr != nil {
			return closeErr
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		for _, entry := range entries {
			rel := entry.Name()
			if dir != "." {
				rel = dir + "/" + rel
			}
			info, err := root.Lstat(rel)
			if err != nil || info.Mode()&os.ModeSymlink != 0 {
				return errors.New("copied source contains an inaccessible path or symlink")
			}
			if info.IsDir() {
				directories[rel] = true
				if err := walk(rel); err != nil {
					return err
				}
				continue
			}
			item, listed := pathSet[rel]
			if !listed || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || !singleLink(info) || !ownedByCurrentUser(info) {
				return errors.New("copied source contains an unlisted, nonregular, or hardlinked entry")
			}
			if prior != nil {
				old, exists := prior[rel]
				if !exists || !os.SameFile(old, info) || old.Size() != info.Size() || !old.ModTime().Equal(info.ModTime()) {
					return fmt.Errorf("copied source file identity changed: %s", rel)
				}
			}
			if err := verifyCopiedFile(root, rel, item, info); err != nil {
				return err
			}
			found[rel] = info
		}
		return nil
	}
	if err := walk("."); err != nil {
		return nil, err
	}
	for directory := range directories {
		if directory == "." {
			continue
		}
		used := false
		for file := range pathSet {
			if strings.HasPrefix(file, directory+"/") {
				used = true
				break
			}
		}
		if !used {
			return nil, errors.New("copied source contains an unlisted empty directory")
		}
	}
	if len(found) != len(pathSet) {
		return nil, errors.New("copied source is missing an inventory file")
	}
	opened, err := root.Stat(".")
	pathNow, pathErr := os.Lstat(source)
	if err != nil || pathErr != nil || !os.SameFile(rootInfo, opened) || !os.SameFile(rootInfo, pathNow) || pathNow.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("copied source root was replaced during logical read")
	}
	return found, nil
}

func verifyCopiedFile(root *os.Root, name string, expected contract.ExportFile, before os.FileInfo) error {
	f, err := root.OpenFile(name, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || opened.Mode().Perm() != 0600 || !singleLink(opened) || !ownedByCurrentUser(opened) || !os.SameFile(before, opened) || opened.Size() != expected.Size {
		f.Close()
		return fmt.Errorf("copied source file differs from inventory: %s", name)
	}
	h := sha256.New()
	n, copyErr := io.Copy(h, f)
	after, statErr := f.Stat()
	closeErr := f.Close()
	if copyErr != nil {
		return copyErr
	}
	if statErr != nil {
		return statErr
	}
	if closeErr != nil {
		return closeErr
	}
	if n != expected.Size || hex.EncodeToString(h.Sum(nil)) != expected.SHA256 || !os.SameFile(opened, after) || after.Size() != opened.Size() || !after.ModTime().Equal(opened.ModTime()) {
		return fmt.Errorf("copied source content differs from inventory: %s", name)
	}
	return nil
}

func safeSnapshotFilePath(value string) bool {
	if value == "" || strings.Contains(value, `\`) || path.IsAbs(value) || path.Clean(value) != value || value == "." {
		return false
	}
	for _, part := range strings.Split(value, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}
