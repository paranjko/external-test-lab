// Package fixtures validates portable fixture integrity before acceptance code
// uses it. It does not classify fixtures as live-network evidence.
package fixtures

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
)

type Manifest struct {
	SchemaVersion int       `json:"schema_version"`
	Fixtures      []Fixture `json:"fixtures"`
}
type Fixture struct {
	ID     string `json:"id"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

func Load(path string) (Manifest, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	err = json.Unmarshal(raw, &manifest)
	return manifest, err
}
func Verify(path string) error {
	manifest, err := Load(path)
	if err != nil {
		return err
	}
	for _, fixture := range manifest.Fixtures {
		raw, err := os.ReadFile(filepath.Join(filepath.Dir(path), fixture.Path))
		if err != nil {
			return err
		}
		sum := sha256.Sum256(raw)
		if hex.EncodeToString(sum[:]) != fixture.SHA256 {
			return os.ErrInvalid
		}
	}
	return nil
}
