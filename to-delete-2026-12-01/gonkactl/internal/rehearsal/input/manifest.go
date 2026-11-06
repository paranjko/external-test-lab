package input

import (
	"encoding/json"
	"fmt"
	"path"
	"strings"

	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"
)

func DecodeSourceManifest(document contract.SignedDocument) (contract.SourceManifest, error) {
	var manifest contract.SourceManifest
	var fields map[string]json.RawMessage
	if err := Decode(document.Payload, &fields); err != nil {
		return manifest, fmt.Errorf("decode source manifest fields: %w", err)
	}
	if fields == nil {
		return manifest, fmt.Errorf("source manifest must be a JSON object")
	}
	if err := exactFields(fields, sourceManifestFields, sourceManifestFields); err != nil {
		return manifest, err
	}
	var heights map[string]json.RawMessage
	if err := Decode(fields["heights"], &heights); err != nil || heights == nil {
		return manifest, fmt.Errorf("source manifest heights must be an object")
	}
	heightFields := map[string]bool{"blockstore": true, "app": true, "consensus": true, "first_repaired": true}
	if err := exactFields(heights, heightFields, heightFields); err != nil {
		return manifest, err
	}
	var files []json.RawMessage
	if err := Decode(fields["files"], &files); err != nil {
		return manifest, err
	}
	for _, rawFile := range files {
		var file map[string]json.RawMessage
		if err := Decode(rawFile, &file); err != nil || file == nil {
			return manifest, fmt.Errorf("source file entry must be an object")
		}
		fileFields := map[string]bool{"path": true, "sha256": true, "size": true}
		if err := exactFields(file, fileFields, fileFields); err != nil {
			return manifest, err
		}
	}
	if err := Decode(document.Payload, &manifest); err != nil {
		return manifest, fmt.Errorf("decode source manifest: %w", err)
	}
	if err := ValidateSourceManifest(manifest); err != nil {
		return manifest, err
	}
	return manifest, nil
}

func ValidateSourceManifest(manifest contract.SourceManifest) error {
	if manifest.SchemaVersion != contract.Version || manifest.Kind != "source_manifest" || manifest.Scope != "capture" {
		return fmt.Errorf("source manifest kind, version, or scope is invalid")
	}
	if manifest.RunID == "" || !contract.IsDigest(manifest.BindingDigest) || manifest.ChainID == "" || !contract.IsDigest(manifest.GenesisSHA256) {
		return fmt.Errorf("source manifest binding is incomplete")
	}
	if manifest.IssuedAt.IsZero() || manifest.ExpiresAt.IsZero() || !manifest.ExpiresAt.After(manifest.IssuedAt) {
		return fmt.Errorf("source manifest validity interval is invalid")
	}
	if manifest.SnapshotID == "" || manifest.Checkpoint == "" || manifest.Backend == "" || manifest.Layout == "" || manifest.BackendVersion == "" || !manifest.Frozen {
		return fmt.Errorf("frozen snapshot metadata is incomplete")
	}
	if manifest.Heights.Blockstore < 1 || manifest.Heights.App < 0 || manifest.Heights.Consensus == nil || *manifest.Heights.Consensus < 0 || manifest.Heights.FirstRepaired < 1 {
		return fmt.Errorf("source heights are incomplete or inconsistent")
	}
	if len(manifest.Files) == 0 || len(manifest.Components) == 0 {
		return fmt.Errorf("source file inventory and components are required")
	}
	seenPaths := make(map[string]bool, len(manifest.Files))
	for _, file := range manifest.Files {
		if !safeRelativePath(file.Path) || seenPaths[file.Path] || !contract.IsDigest(file.SHA256) || file.Size < 0 {
			return fmt.Errorf("source file inventory contains an invalid entry")
		}
		seenPaths[file.Path] = true
	}
	seenComponents := make(map[string]bool, len(manifest.Components))
	for _, component := range manifest.Components {
		if component == "" || seenComponents[component] {
			return fmt.Errorf("source component inventory is invalid")
		}
		seenComponents[component] = true
	}
	return nil
}

func VerifySourceManifest(document contract.SignedDocument, policy VerificationPolicy) (contract.SourceManifest, error) {
	manifest, err := DecodeSourceManifest(document)
	if err != nil {
		return manifest, err
	}
	if _, err := VerifyDocument(document, policy); err != nil {
		return manifest, err
	}
	if !sameHeights(manifest.Heights, policy.Binding.Heights) {
		return manifest, fmt.Errorf("source manifest heights do not match run binding")
	}
	return manifest, nil
}

func sameHeights(left, right contract.Heights) bool {
	if left.Blockstore != right.Blockstore || left.App != right.App || left.FirstRepaired != right.FirstRepaired || left.Consensus == nil || right.Consensus == nil {
		return false
	}
	return *left.Consensus == *right.Consensus
}

func safeRelativePath(value string) bool {
	if value == "" || strings.Contains(value, `\`) || strings.HasPrefix(value, "/") || path.Clean(value) != value || value == "." || strings.HasPrefix(value, "../") {
		return false
	}
	for _, part := range strings.Split(value, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
		lower := strings.ToLower(part)
		for _, forbidden := range []string{"key", "signer", "tmkms", "secret", "credential", "ssh", ".env", "gateway", "ml-"} {
			if strings.Contains(lower, forbidden) {
				return false
			}
		}
	}
	return true
}
