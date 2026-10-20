package contract

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
)

var identifier = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$`)

func IsDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil && s == string(bytes.ToLower([]byte(s)))
}

// ValidateBinding checks structural safety, not source authenticity or Core qualification.
func ValidateBinding(b RunBinding) error {
	if b.SchemaVersion != Version || b.Scenario != Scenario || !identifier.MatchString(b.RunID) || !identifier.MatchString(b.OwnershipMarker) {
		return errors.New("invalid rehearsal identity")
	}
	if !filepath.IsAbs(b.Workspace) || filepath.Clean(b.Workspace) != b.Workspace || b.Workspace == string(filepath.Separator) {
		return errors.New("workspace must be a clean absolute non-root path")
	}
	if b.ChainID == "" || !IsDigest(b.GenesisSHA256) || b.ToolVersion == "" || b.CatalogVersion == "" {
		return errors.New("missing chain or version binding")
	}
	if b.Heights.Blockstore < 0 || b.Heights.App < 0 || b.Heights.FirstRepaired < 0 || b.Heights.Consensus != nil && *b.Heights.Consensus < 0 || b.AppHashHeight != b.Heights.App {
		return errors.New("invalid height binding")
	}
	if b.BlockID == "" || b.AppHash == "" || len(b.InputDigests) == 0 || len(b.RuntimeIdentities) == 0 {
		return errors.New("incomplete source or runtime binding")
	}
	for name, digest := range b.InputDigests {
		if name == "" || !IsDigest(digest) {
			return errors.New("invalid input digest")
		}
	}
	for name, identity := range b.RuntimeIdentities {
		if name == "" || identity == "" {
			return errors.New("invalid runtime identity")
		}
	}
	for name, path := range b.Paths {
		// Frozen exports and independent peer journals are read-only references
		// from this run. The peer owns writes under its own immutable binding.
		if name == "export" || name == "peer_workspace" {
			if !filepath.IsAbs(path) || filepath.Clean(path) != path || path == string(filepath.Separator) || path == b.Workspace {
				return errors.New("read-only reference must be a clean absolute non-root path distinct from workspace")
			}
			continue
		}
		rel, err := filepath.Rel(b.Workspace, path)
		if name == "" || err != nil || !filepath.IsAbs(path) || filepath.Clean(path) != path || rel == "." || rel == ".." || len(rel) > 3 && rel[:3] == ".."+string(filepath.Separator) {
			return errors.New("bound path escapes workspace")
		}
	}
	return nil
}

func ValidPhase(p Phase) bool {
	switch p {
	case Inspect, Capture, Stage, Run, Verify, Report, Cleanup:
		return true
	}
	return false
}

func ValidateReceipt(r Receipt, b RunBinding) error {
	digest, err := Digest(b)
	if err != nil {
		return err
	}
	if r.SchemaVersion != Version || r.RunID != b.RunID || r.BindingDigest != digest || !ValidPhase(r.Phase) || r.Operation == "" || r.Sequence == 0 {
		return errors.New("receipt does not match run binding")
	}
	switch r.State {
	case Planned, Running, Succeeded, Failed, Blocked, Unknown:
	default:
		return errors.New("invalid receipt state")
	}
	if r.Predecessor != "" && !IsDigest(r.Predecessor) {
		return errors.New("invalid receipt predecessor")
	}
	for name, value := range r.EvidenceDigests {
		if name == "" || !IsDigest(value) {
			return errors.New("invalid evidence digest")
		}
	}
	if r.State == Succeeded && r.ExitCode != nil && *r.ExitCode != 0 {
		return errors.New("successful receipt has failing exit code")
	}
	return nil
}

// DecodeStrict rejects duplicate keys at every depth and trailing JSON, before
// decoding with unknown fields rejected. Signed callers retain the original bytes.
func DecodeStrict(data []byte, out any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	if err := uniqueValue(d); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("trailing JSON")
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	return d.Decode(out)
}

func uniqueValue(d *json.Decoder) error {
	token, err := d.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for d.More() {
			key, err := d.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok {
				return errors.New("invalid object key")
			}
			if seen[name] {
				return fmt.Errorf("duplicate JSON key %q", name)
			}
			seen[name] = true
			if err := uniqueValue(d); err != nil {
				return err
			}
		}
	case '[':
		for d.More() {
			if err := uniqueValue(d); err != nil {
				return err
			}
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	_, err = d.Token()
	return err
}
